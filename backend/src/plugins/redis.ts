import fp from 'fastify-plugin';
import Redis from 'ioredis';
import type { FastifyInstance } from 'fastify';

declare module 'fastify' {
  interface FastifyInstance {
    redis: Redis;
    redisSub: Redis;
  }
}

export default fp(async (fastify: FastifyInstance) => {
  const redis = new Redis(fastify.config.REDIS_URL, {
    maxRetriesPerRequest: 3,
    lazyConnect: true,
    retryStrategy(times) {
      return Math.min(times * 200, 3000);
    },
  });

  // Separate connection for pub/sub (pub/sub blocks the connection)
  const redisSub = new Redis(fastify.config.REDIS_URL, {
    maxRetriesPerRequest: 3,
    lazyConnect: true,
    retryStrategy(times) {
      return Math.min(times * 200, 3000);
    },
  });

  // Prevent unhandled error events from crashing the process
  redis.on('error', (err) => fastify.log.warn({ err: err.message }, 'Redis error'));
  redisSub.on('error', (err) => fastify.log.warn({ err: err.message }, 'Redis sub error'));

  await redis.connect();
  await redisSub.connect();

  fastify.decorate('redis', redis);
  fastify.decorate('redisSub', redisSub);

  fastify.addHook('onClose', async () => {
    await redis.quit();
    await redisSub.quit();
  });
});
