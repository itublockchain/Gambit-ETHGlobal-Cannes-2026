import type { FastifyInstance } from 'fastify';
import { eq } from 'drizzle-orm';
import { positions } from '../../db/schema.js';
import { POLYMARKET_DATA_URL } from '../../config.js';

/**
 * Get user's positions from DB, enriched with live PnL from Polymarket Data API.
 */
export async function getUserPositions(fastify: FastifyInstance, userId: string) {
  const dbPositions = await fastify.db.query.positions.findMany({
    where: eq(positions.userId, userId),
    orderBy: (positions, { desc }) => [desc(positions.updatedAt)],
  });

  return dbPositions;
}

/**
 * Fetch live positions from Polymarket Data API (public, no auth).
 */
export async function fetchLivePositions(walletAddress: string) {
  const res = await fetch(
    `${POLYMARKET_DATA_URL}/positions?user=${walletAddress}`,
  );
  if (!res.ok) return [];
  return res.json();
}
