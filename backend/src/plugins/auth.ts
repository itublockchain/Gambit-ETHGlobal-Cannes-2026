import fp from 'fastify-plugin';
import fjwt from '@fastify/jwt';
import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';

declare module '@fastify/jwt' {
  interface FastifyJWT {
    payload: { userId: string; walletAddress: string };
    user: { userId: string; walletAddress: string };
  }
}

export default fp(async (fastify: FastifyInstance) => {
  await fastify.register(fjwt, {
    secret: fastify.config.JWT_SECRET,
    sign: { expiresIn: '7d' },
  });

  fastify.decorate('authenticate', async (request: FastifyRequest, reply: FastifyReply) => {
    try {
      await request.jwtVerify();
    } catch (err) {
      const authHeader = request.headers.authorization;
      fastify.log.warn({ authHeader: authHeader ? `${authHeader.substring(0, 30)}...` : 'MISSING', err: (err as Error).message }, 'JWT auth failed');
      reply.status(401).send({ error: 'Unauthorized' });
    }
  });
});

declare module 'fastify' {
  interface FastifyInstance {
    authenticate: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}
