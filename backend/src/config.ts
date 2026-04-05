import 'dotenv/config';
import { z } from 'zod';

const envSchema = z.object({
  // Database
  DATABASE_URL: z.string().min(1),

  // Redis
  REDIS_URL: z.string().default('redis://localhost:6379'),

  // Dynamic.xyz
  DYNAMIC_ENVIRONMENT_ID: z.string().min(1),
  DYNAMIC_API_KEY: z.string().min(1),
  DYNAMIC_RSA_PRIVATE_KEY: z.string().min(1).transform((v) => v.replace(/\\n/g, '\n')),

  // JWT
  JWT_SECRET: z.string().min(16),

  // Server
  PORT: z.coerce.number().default(3000),
  HOST: z.string().default('0.0.0.0'),
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),

  // Encryption key for delegation materials at rest (hex-encoded 32 bytes)
  ENCRYPTION_KEY: z.string().min(1),
});

export type Env = z.infer<typeof envSchema>;

let _config: Env | null = null;

export function loadConfig(): Env {
  if (_config) return _config;

  const result = envSchema.safeParse(process.env);
  if (!result.success) {
    const missing = result.error.issues
      .map((i) => `  ${i.path.join('.')}: ${i.message}`)
      .join('\n');
    console.error(`❌ Invalid environment variables:\n${missing}`);
    process.exit(1);
  }

  _config = result.data;
  return _config;
}

// Constants
export const POLYGON_CHAIN_ID = 137;
export const POLYMARKET_CLOB_URL = 'https://clob.polymarket.com';
export const POLYMARKET_GAMMA_URL = 'https://gamma-api.polymarket.com';
export const POLYMARKET_DATA_URL = 'https://data-api.polymarket.com';
export const POLYMARKET_WS_URL = 'wss://ws-subscriptions-clob.polymarket.com/ws/market';
export const DYNAMIC_JWKS_URL = (envId: string) =>
  `https://app.dynamicauth.com/api/v0/sdk/${envId}/.well-known/jwks`;

export const SUPPORTED_ASSETS = ['btc', 'eth', 'xrp'] as const;
export type SupportedAsset = (typeof SUPPORTED_ASSETS)[number];
