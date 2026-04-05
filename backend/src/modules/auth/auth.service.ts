import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { FastifyInstance } from 'fastify';
import { eq } from 'drizzle-orm';
import { users, userWallets } from '../../db/schema.js';
import { DYNAMIC_JWKS_URL } from '../../config.js';
import { UnauthorizedError } from '../../lib/errors.js';
import crypto from 'node:crypto';

// Cache JWKS
let _jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

function getJWKS(environmentId: string) {
  if (!_jwks) {
    _jwks = createRemoteJWKSet(new URL(DYNAMIC_JWKS_URL(environmentId)));
  }
  return _jwks;
}

export interface DynamicJwtPayload {
  sub: string; // Dynamic user ID
  email?: string;
  given_name?: string;
  family_name?: string;
  iss: string;
  aud: string;
}

/**
 * Verify a Dynamic-issued JWT and extract user info.
 */
export async function verifyDynamicToken(
  fastify: FastifyInstance,
  dynamicJwt: string,
): Promise<DynamicJwtPayload> {
  const jwks = getJWKS(fastify.config.DYNAMIC_ENVIRONMENT_ID);
  const expectedIssuer = `app.dynamicauth.com/${fastify.config.DYNAMIC_ENVIRONMENT_ID}`;

  fastify.log.info(`verifyDynamicToken — expected issuer: ${expectedIssuer}`);

  // Decode header and payload without verification first for debugging
  const parts = dynamicJwt.split('.');
  if (parts.length === 3) {
    try {
      const header = JSON.parse(Buffer.from(parts[0], 'base64url').toString());
      const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
      fastify.log.info({ header, iss: payload.iss, sub: payload.sub, exp: payload.exp }, 'JWT decoded (unverified)');
    } catch { /* ignore */ }
  }

  try {
    const { payload } = await jwtVerify(dynamicJwt, jwks, {
      issuer: expectedIssuer,
    });
    fastify.log.info('JWT verification succeeded');
    return payload as unknown as DynamicJwtPayload;
  } catch (err) {
    fastify.log.error({ err }, 'JWT verification failed');
    throw new UnauthorizedError('Invalid Dynamic token');
  }
}

/**
 * Find or create user from Dynamic auth, return session JWT.
 */
export async function authenticateUser(
  fastify: FastifyInstance,
  dynamicJwt: string,
): Promise<{ sessionToken: string; userId: string; isNewUser: boolean }> {
  const payload = await verifyDynamicToken(fastify, dynamicJwt);

  // Upsert user
  const existing = await fastify.db.query.users.findFirst({
    where: eq(users.dynamicUserId, payload.sub),
  });

  let userId: string;
  let isNewUser = false;

  if (existing) {
    userId = existing.id;
    // Update display name if changed
    const displayName = [payload.given_name, payload.family_name].filter(Boolean).join(' ');
    if (displayName && displayName !== existing.displayName) {
      await fastify.db
        .update(users)
        .set({ displayName, updatedAt: new Date() })
        .where(eq(users.id, userId));
    }
  } else {
    const displayName = [payload.given_name, payload.family_name].filter(Boolean).join(' ');
    const [newUser] = await fastify.db
      .insert(users)
      .values({
        dynamicUserId: payload.sub,
        email: payload.email,
        displayName: displayName || null,
      })
      .returning({ id: users.id });
    userId = newUser.id;
    isNewUser = true;
  }

  // Get wallet address if delegation exists
  const wallet = await fastify.db.query.userWallets.findFirst({
    where: eq(userWallets.userId, userId),
  });

  const sessionToken = fastify.jwt.sign({
    userId,
    walletAddress: wallet?.walletAddress ?? '',
  });

  return { sessionToken, userId, isNewUser };
}

/**
 * Check if a user has active delegation.
 */
export async function getDelegationStatus(
  fastify: FastifyInstance,
  userId: string,
): Promise<{ delegated: boolean; walletAddress: string | null; usdcBalance: string | null }> {
  // Verify user exists — stale session tokens may reference deleted users
  const user = await fastify.db.query.users.findFirst({
    where: eq(users.id, userId),
  });
  if (!user) {
    throw new UnauthorizedError('User not found — please log in again');
  }

  const wallet = await fastify.db.query.userWallets.findFirst({
    where: eq(userWallets.userId, userId),
  });

  let usdcBalance: string | null = null;
  let isDelegated = wallet?.delegationStatus === 'active';
  const walletAddress = wallet?.walletAddress ?? null;

  // Fallback: if user_wallets has no active row, check if Redis has CLOB creds
  // (can happen if submit-clob-auth stored creds but DB row is stale)
  if (!isDelegated && walletAddress) {
    const redisCreds = await fastify.redis.get(`clob_creds:${walletAddress}`);
    if (redisCreds) {
      isDelegated = true;
    }
  }

  if (walletAddress) {
    try {
      usdcBalance = await getUSDCBalance(walletAddress);
    } catch (err) {
      fastify.log.warn({ err }, 'Failed to fetch USDC balance');
    }
  }

  return {
    delegated: isDelegated,
    walletAddress,
    usdcBalance,
  };
}

/**
 * Fetch USDC balance on Polygon for a wallet address.
 */
async function getUSDCBalance(walletAddress: string): Promise<string> {
  // USDC on Polygon (PoS): 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
  // USDC.e (bridged): 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174
  const USDC_ADDRESS = '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359';
  const USDC_E_ADDRESS = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174';

  // ERC20 balanceOf(address) selector = 0x70a08231
  const callData = `0x70a08231000000000000000000000000${walletAddress.slice(2)}`;

  let totalBalance = 0;

  for (const tokenAddress of [USDC_ADDRESS, USDC_E_ADDRESS]) {
    try {
      const res = await fetch('https://polygon-bor-rpc.publicnode.com', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          method: 'eth_call',
          params: [{ to: tokenAddress, data: callData }, 'latest'],
          id: 1,
        }),
      });
      const data = (await res.json()) as { result: string };
      if (data.result && data.result !== '0x') {
        const balance = parseInt(data.result, 16) / 1e6; // USDC has 6 decimals
        totalBalance += balance;
      }
    } catch {
      // Skip this token
    }
  }

  return totalBalance.toFixed(2);
}

/**
 * Verify webhook signature from Dynamic.
 */
export function verifyWebhookSignature(
  payload: string,
  signature: string,
  secret: string,
): boolean {
  const expected = crypto.createHmac('sha256', secret).update(payload).digest('hex');
  const sig = signature.startsWith('sha256=') ? signature.slice(7) : signature;
  return crypto.timingSafeEqual(Buffer.from(expected, 'hex'), Buffer.from(sig, 'hex'));
}
