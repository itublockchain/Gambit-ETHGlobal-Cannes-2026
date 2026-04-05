import fp from 'fastify-plugin';
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import type { FastifyInstance } from 'fastify';
import * as schema from '../db/schema.js';

declare module 'fastify' {
  interface FastifyInstance {
    db: ReturnType<typeof drizzle<typeof schema>>;
  }
}

export default fp(async (fastify: FastifyInstance) => {
  const sql = postgres(fastify.config.DATABASE_URL, {
    max: 10,
    idle_timeout: 20,
    connect_timeout: 10,
  });

  const db = drizzle(sql, { schema });

  fastify.decorate('db', db);

  fastify.addHook('onClose', async () => {
    await sql.end();
  });
});
