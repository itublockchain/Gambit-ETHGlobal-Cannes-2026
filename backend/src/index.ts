import Fastify from 'fastify';
import cors from '@fastify/cors';
import { loadConfig, type Env } from './config.js';
import postgresPlugin from './plugins/postgres.js';
import redisPlugin from './plugins/redis.js';
import authPlugin from './plugins/auth.js';
import websocketPlugin from './plugins/websocket.js';
import { AppError } from './lib/errors.js';
import { initPricePipeline } from './modules/prices/prices.service.js';

// Routes
import authRoutes from './modules/auth/auth.routes.js';
import marketsRoutes from './modules/markets/markets.routes.js';
import ordersRoutes from './modules/orders/orders.routes.js';
import positionsRoutes from './modules/positions/positions.routes.js';
import pricesWs from './modules/prices/prices.ws.js';
import walletRoutes from './modules/wallet/wallet.routes.js';
import { autoSwapAndApprove } from './modules/wallet/wallet.service.js';
import { prewarmOrderPipeline } from './modules/orders/orders.service.js';
import { startPriceStream } from './modules/markets/markets.service.js';
import cron from 'node-cron';

declare module 'fastify' {
  interface FastifyInstance {
    config: Env;
  }
}

async function buildApp() {
  const config = loadConfig();

  const app = Fastify({
    logger: {
      level: config.NODE_ENV === 'production' ? 'info' : 'debug',
    },
  });

  // Config decorator
  app.decorate('config', config);

  // CORS
  await app.register(cors, { origin: true });

  // Plugins
  await app.register(postgresPlugin);
  await app.register(redisPlugin);
  await app.register(authPlugin);
  await app.register(websocketPlugin);

  // Error handler
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof AppError) {
      reply.status(error.statusCode).send({
        error: error.code,
        message: error.message,
      });
      return;
    }

    app.log.error(error);
    reply.status(500).send({
      error: 'INTERNAL_ERROR',
      message: config.NODE_ENV === 'production' ? 'Internal server error' : (error as Error).message,
    });
  });

  // Log ALL incoming requests for debugging
  app.addHook('onRequest', async (request) => {
    if (request.url !== '/api/v1/auth/delegation-status') {
      app.log.info({ method: request.method, url: request.url, host: request.headers.host }, '>>> INCOMING REQUEST');
    }
  });

  // Health check
  app.get('/health', async () => ({ status: 'ok', timestamp: new Date().toISOString() }));

  // API routes
  await app.register(authRoutes, { prefix: '/api/v1/auth' });
  await app.register(marketsRoutes, { prefix: '/api/v1/markets' });
  await app.register(ordersRoutes, { prefix: '/api/v1/orders' });
  await app.register(positionsRoutes, { prefix: '/api/v1/positions' });
  await app.register(pricesWs, { prefix: '/ws' });
  await app.register(walletRoutes, { prefix: '/api/v1/wallet' });

  // Initialize price pipeline (Polymarket WS → Redis → clients)
  await initPricePipeline(app);

  // Pre-warm order pipeline (L2 creds + USDC approval) in background
  prewarmOrderPipeline(app).catch(() => {});

  // Auto-swap USDC → USDC.e + approve every 2 minutes
  cron.schedule('*/2 * * * *', () => {
    autoSwapAndApprove(app).catch((err) => app.log.error(err, 'Auto-swap cron error'));
  });

  return app;
}

// Catch unhandled errors to prevent silent crashes
process.on('uncaughtException', (err) => {
  console.error('UNCAUGHT EXCEPTION:', err);
});
process.on('unhandledRejection', (reason) => {
  console.error('UNHANDLED REJECTION:', reason);
});

async function start() {
  const app = await buildApp();
  const config = loadConfig();

  try {
    await app.listen({ port: config.PORT, host: config.HOST });
    app.log.info(`Server running on http://${config.HOST}:${config.PORT}`);

    // Start Binance price stream AFTER server is listening (needs event loop free)
    startPriceStream(app);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

start();
