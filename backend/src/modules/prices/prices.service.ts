import type { FastifyInstance } from 'fastify';
import { PolymarketWSConsumer } from '../../lib/polymarket/ws-consumer.js';
import { SUPPORTED_ASSETS } from '../../config.js';
import { findActiveMarket } from '../../lib/polymarket/gamma-client.js';
import cron from 'node-cron';

let wsConsumer: PolymarketWSConsumer | null = null;

/**
 * Initialize the Polymarket WebSocket consumer and market rotation cron.
 */
export async function initPricePipeline(fastify: FastifyInstance): Promise<void> {
  wsConsumer = new PolymarketWSConsumer(fastify.redis, fastify.log);
  wsConsumer.connect();

  // Initial subscription
  await rotateMarkets(fastify);

  // Rotate markets every 1 minute (5-min markets need frequent updates)
  cron.schedule('* * * * *', async () => {
    await rotateMarkets(fastify);
  });

  fastify.addHook('onClose', async () => {
    await wsConsumer?.shutdown();
  });
}

/**
 * Discover active markets and update WebSocket subscriptions.
 */
async function rotateMarkets(fastify: FastifyInstance): Promise<void> {
  for (const asset of SUPPORTED_ASSETS) {
    try {
      const market = await findActiveMarket(asset);
      if (!market) continue;

      // Get previously tracked token IDs
      const prevData = await fastify.redis.get(`active_market:${asset}`);
      const prevTokenIds: string[] = [];
      if (prevData) {
        const prev = JSON.parse(prevData);
        prevTokenIds.push(prev.upTokenId, prev.downTokenId);
      }

      const newTokenIds = [market.upTokenId, market.downTokenId];

      // Update subscription if tokens changed
      if (
        prevTokenIds[0] !== newTokenIds[0] ||
        prevTokenIds[1] !== newTokenIds[1]
      ) {
        wsConsumer?.rotateSubscriptions(prevTokenIds, newTokenIds);
        fastify.log.info(`Market rotated for ${asset}: ${market.slug}`);
      }

      // Cache active market with prices — only if prices available
      const { getTokenPrice } = await import('../../lib/polymarket/gamma-client.js');
      const [upPrice, downPrice] = await Promise.all([
        getTokenPrice(market.upTokenId).catch(() => null),
        getTokenPrice(market.downTokenId).catch(() => null),
      ]);
      if (upPrice && downPrice) {
        await fastify.redis.set(
          `active_market:${asset}`,
          JSON.stringify({ ...market, asset, upPrice, downPrice }),
          'EX',
          120, // shorter TTL — markets rotate every 5 min
        );
      } else {
        // Don't cache without prices — old cache with prices is better
        fastify.log.warn(`Skipping cache for ${asset} — prices null`);
      }
    } catch (err) {
      fastify.log.error(`Market rotation failed for ${asset}: ${err}`);
    }
  }
}

export { wsConsumer };
