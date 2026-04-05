import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { getUserPositions } from './positions.service.js';

export default async function positionsRoutes(fastify: FastifyInstance) {
  fastify.addHook('preHandler', fastify.authenticate);

  /**
   * GET /positions
   * Get user's active positions with PnL.
   */
  fastify.get('/', async (request: FastifyRequest, reply: FastifyReply) => {
    const { userId } = request.user;
    const userPositions = await getUserPositions(fastify, userId);
    return reply.send({ positions: userPositions });
  });
}
