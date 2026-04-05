import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { getActiveMarkets, getLatestPrices, getCryptoSpotPrices, getPriceHistory, startPriceStream } from './markets.service.js';

export default async function marketsRoutes(fastify: FastifyInstance) {
  // Binance WS is started after server listen (in index.ts) to avoid event loop blocking

  /**
   * GET /markets/active
   * Get active 5-minute markets for BTC, ETH, XRP with spot prices + odds.
   */
  fastify.get('/active', async (_request: FastifyRequest, reply: FastifyReply) => {
    const [markets, spotPrices] = await Promise.all([
      getActiveMarkets(fastify),
      getCryptoSpotPrices(fastify),
    ]);

    const enriched = markets.map((m) => ({
      ...m,
      spotPrice: spotPrices[m.asset] ?? null,
    }));

    // Include user bet amount from DB
    let defaultBetAmount = 5;
    try {
      const wallet = await fastify.db.query.userWallets.findFirst({
        where: (w: any, { eq }: any) => eq(w.delegationStatus, 'active'),
      });
      if (wallet) {
        const user = await fastify.db.query.users.findFirst({
          where: (u: any, { eq }: any) => eq(u.id, wallet.userId),
        });
        if (user?.defaultBetAmount) defaultBetAmount = parseFloat(user.defaultBetAmount);
      }
    } catch {}

    return reply.send({ markets: enriched, spotPrices, defaultBetAmount });
  });

  /**
   * GET /markets/prices
   * Lightweight endpoint — spot prices + odds.
   */
  fastify.get('/prices', async (_request: FastifyRequest, reply: FastifyReply) => {
    const [prices, spotPrices] = await Promise.all([
      getLatestPrices(fastify),
      getCryptoSpotPrices(fastify),
    ]);
    return reply.send({ prices, spotPrices, timestamp: Date.now() });
  });

  /**
   * GET /markets/history
   * Last 5 minutes of price data for chart pre-fill.
   */
  fastify.get('/history', async (_request: FastifyRequest, reply: FastifyReply) => {
    const history = await getPriceHistory(fastify);
    return reply.send({ history });
  });

  /**
   * GET /markets/stream
   * Server-Sent Events — continuous price stream for Watch.
   */
  fastify.get('/stream', async (request: FastifyRequest, reply: FastifyReply) => {
    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no',
    });

    // Send prices every 500ms from Redis cache (updated by Binance WS)
    const interval = setInterval(async () => {
      try {
        const spotPrices = await getCryptoSpotPrices(fastify);
        const data = JSON.stringify({ spotPrices, t: Date.now() });
        reply.raw.write(`data: ${data}\n\n`);
      } catch {
        // Ignore
      }
    }, 500);

    // Cleanup on disconnect
    request.raw.on('close', () => {
      clearInterval(interval);
    });
  });
}
