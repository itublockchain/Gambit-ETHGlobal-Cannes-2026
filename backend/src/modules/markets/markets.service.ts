import type { FastifyInstance } from 'fastify';
import WS from 'ws';
import { findActiveMarket, getTokenPrice } from '../../lib/polymarket/gamma-client.js';
import { SUPPORTED_ASSETS, type SupportedAsset } from '../../config.js';
import type { ActiveMarket, MarketPrice } from '../../types/polymarket.js';

const MARKET_CACHE_TTL = 60; // 1 minute — markets rotate every 5 min
const PRICE_CACHE_TTL = 5; // 5 seconds

export interface ActiveMarketWithPrices extends ActiveMarket {
  asset: SupportedAsset;
  upPrice: string;
  downPrice: string;
}

/**
 * Get all active 5-minute markets with current prices.
 * Cached in Redis for performance.
 */
export async function getActiveMarkets(
  fastify: FastifyInstance,
): Promise<ActiveMarketWithPrices[]> {
  const results: ActiveMarketWithPrices[] = [];

  for (const asset of SUPPORTED_ASSETS) {
    try {
      // Check Redis cache first — but only if it has prices
      const cached = await fastify.redis.get(`active_market:${asset}`);
      if (cached) {
        const parsed = JSON.parse(cached);
        if (parsed.upPrice && parsed.downPrice) {
          results.push(parsed);
          continue;
        }
      }

      // Discover market
      const market = await findActiveMarket(asset);
      if (!market) {
        fastify.log.warn(`No live market for ${asset}`);
        continue;
      }
      fastify.log.info(`Found live market for ${asset}: ${market.slug}`);

      // Fetch prices
      const [upPrice, downPrice] = await Promise.all([
        getTokenPrice(market.upTokenId),
        getTokenPrice(market.downTokenId),
      ]);

      const marketWithPrices: ActiveMarketWithPrices = {
        ...market,
        asset,
        upPrice,
        downPrice,
      };

      // Cache
      await fastify.redis.set(
        `active_market:${asset}`,
        JSON.stringify(marketWithPrices),
        'EX',
        MARKET_CACHE_TTL,
      );

      results.push(marketWithPrices);
    } catch (err) {
      fastify.log.error({ err: (err as Error).message }, `Failed to fetch market for ${asset}`);
    }
  }

  return results;
}

/**
 * Get a single active market for an asset.
 */
export async function getActiveMarketForAsset(
  fastify: FastifyInstance,
  asset: SupportedAsset,
): Promise<ActiveMarketWithPrices | null> {
  // Check cache
  const cached = await fastify.redis.get(`active_market:${asset}`);
  if (cached) return JSON.parse(cached);

  const market = await findActiveMarket(asset);
  if (!market) return null;

  const [upPrice, downPrice] = await Promise.all([
    getTokenPrice(market.upTokenId),
    getTokenPrice(market.downTokenId),
  ]);

  const result: ActiveMarketWithPrices = { ...market, asset, upPrice, downPrice };
  await fastify.redis.set(`active_market:${asset}`, JSON.stringify(result), 'EX', MARKET_CACHE_TTL);

  return result;
}

/**
 * Get latest cached prices for all active markets.
 * Used by Watch HTTP fallback polling.
 */
export async function getLatestPrices(
  fastify: FastifyInstance,
): Promise<Record<SupportedAsset, MarketPrice | null>> {
  const result = {} as Record<SupportedAsset, MarketPrice | null>;

  for (const asset of SUPPORTED_ASSETS) {
    const cached = await fastify.redis.get(`price:${asset}`);
    result[asset] = cached ? JSON.parse(cached) : null;
  }

  return result;
}

/**
 * Get last 5 minutes of price history for all assets.
 */
export async function getPriceHistory(
  fastify: FastifyInstance,
): Promise<Record<SupportedAsset, Array<{ t: number; p: number }>>> {
  const result = { btc: [], eth: [], xrp: [] } as Record<SupportedAsset, Array<{ t: number; p: number }>>;

  for (const asset of SUPPORTED_ASSETS) {
    const raw = await fastify.redis.lrange(`price_history:${asset}`, 0, -1);
    result[asset] = raw.map((s) => JSON.parse(s));
  }

  return result;
}

/**
 * Get spot prices from Redis (updated by Binance WebSocket).
 */
export async function getCryptoSpotPrices(
  fastify: FastifyInstance,
): Promise<Record<SupportedAsset, number | null>> {
  const cacheKey = 'spot_prices';
  const cached = await fastify.redis.get(cacheKey);
  if (cached) return JSON.parse(cached);
  return { btc: null, eth: null, xrp: null };
}

/**
 * Binance WebSocket — real-time crypto prices.
 */
export function startPriceStream(fastify: FastifyInstance) {
  const cacheKey = 'spot_prices';

  function connectWS() {
    const symbols = ['btcusdt@trade', 'ethusdt@trade', 'xrpusdt@trade'];
    const ws = new WS(`wss://stream.binance.com:9443/ws/${symbols.join('/')}`);

    let lastMessageTime = Date.now();
    let pingInterval: ReturnType<typeof setInterval>;

    ws.on('open', () => {
      fastify.log.info('Binance WebSocket connected — live prices');
      lastMessageTime = Date.now();

      // Heartbeat: if no message for 30s, force reconnect
      pingInterval = setInterval(() => {
        if (Date.now() - lastMessageTime > 30000) {
          fastify.log.warn('Binance WS stale (no data 30s), forcing reconnect...');
          clearInterval(pingInterval);
          ws.terminate();
        }
      }, 10000);
    });

    ws.on('message', async (data: Buffer) => {
      lastMessageTime = Date.now();
      try {
        const msg = JSON.parse(data.toString()) as { s: string; p: string };
        const map: Record<string, SupportedAsset> = { BTCUSDT: 'btc', ETHUSDT: 'eth', XRPUSDT: 'xrp' };
        const asset = map[msg.s];
        if (!asset) return;
        const price = parseFloat(msg.p);
        const now = Date.now();

        const cached = await fastify.redis.get(cacheKey);
        const prices = cached ? JSON.parse(cached) : { btc: null, eth: null, xrp: null };
        prices[asset] = price;
        await fastify.redis.set(cacheKey, JSON.stringify(prices), 'EX', 120);

        const histKey = `price_history:${asset}`;
        const lastKey = `price_history_last:${asset}`;
        const lastTs = await fastify.redis.get(lastKey);
        if (!lastTs || now - parseInt(lastTs) >= 1000) {
          await fastify.redis.rpush(histKey, JSON.stringify({ t: now, p: price }));
          await fastify.redis.ltrim(histKey, -300, -1);
          await fastify.redis.set(lastKey, now.toString(), 'EX', 600);
        }
      } catch {}
    });

    ws.on('close', () => {
      fastify.log.info('Binance WS closed, reconnecting in 2s...');
      clearInterval(pingInterval);
      setTimeout(connectWS, 2000);
    });
    ws.on('error', (err: Error) => {
      fastify.log.error({ err: err.message }, 'Binance WS error');
      clearInterval(pingInterval);
    });
  }

  fastify.log.info('Connecting to Binance WebSocket...');
  connectWS();
}
