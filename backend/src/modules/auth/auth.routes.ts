import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { eq } from 'drizzle-orm';
import { authenticateUser, getDelegationStatus, verifyWebhookSignature } from './auth.service.js';
import {
  storeDelegationMaterials,
  decryptHybridRsaAes,
} from '../../lib/dynamic/delegation.js';
import { verifyTokenSchema, delegationWebhookSchema } from './auth.schema.js';
import { users, userWallets } from '../../db/schema.js';
import { AppError } from '../../lib/errors.js';
import { POLYMARKET_CLOB_URL, POLYGON_CHAIN_ID } from '../../config.js';

export default async function authRoutes(fastify: FastifyInstance) {
  /**
   * POST /auth/verify
   * Verify Dynamic JWT, create/find user, return session token.
   */
  fastify.post('/verify', async (request: FastifyRequest, reply: FastifyReply) => {
    fastify.log.info('POST /auth/verify — received request');
    try {
      const body = verifyTokenSchema.parse(request.body);
      fastify.log.info(`POST /auth/verify — JWT length: ${body.dynamicJwt.length}`);

      const result = await authenticateUser(fastify, body.dynamicJwt);
      fastify.log.info(`POST /auth/verify — success, userId: ${result.userId}, isNew: ${result.isNewUser}`);

      return reply.send({
        sessionToken: result.sessionToken,
        userId: result.userId,
        isNewUser: result.isNewUser,
      });
    } catch (err) {
      fastify.log.error({ err }, 'POST /auth/verify — FAILED');
      throw err;
    }
  });

  /**
   * GET /auth/delegation-status
   * Check if user has active delegation (authenticated).
   */
  fastify.get(
    '/delegation-status',
    { preHandler: [fastify.authenticate] },
    async (request: FastifyRequest, reply: FastifyReply) => {
      const { userId } = request.user;
      fastify.log.info(`GET /delegation-status — userId: ${userId}`);
      const status = await getDelegationStatus(fastify, userId);
      fastify.log.info({ userId, ...status }, 'GET /delegation-status — result');
      return reply.send(status);
    },
  );

  /**
   * POST /auth/settings
   * Update user settings (bet amount etc) — requires JWT auth.
   */
  fastify.post('/settings', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as { defaultBetAmount?: number };
    const { userId } = request.user;

    if (body.defaultBetAmount) {
      await fastify.db
        .update(users)
        .set({ defaultBetAmount: body.defaultBetAmount.toFixed(2), updatedAt: new Date() })
        .where(eq(users.id, userId));
    }

    return reply.send({ success: true });
  });

  /**
   * POST /auth/clob-auth-data
   * Returns ClobAuth EIP-712 typed data for iOS client-side signing.
   */
  fastify.post(
    '/clob-auth-data',
    { preHandler: [fastify.authenticate] },
    async (request: FastifyRequest, reply: FastifyReply) => {
      const body = request.body as { walletAddress: string };
      if (!body.walletAddress) {
        return reply.status(400).send({ error: 'walletAddress is required' });
      }

      // Use Polymarket server time — signatures must match their clock
      let timestamp: string;
      try {
        const timeRes = await fetch(`${POLYMARKET_CLOB_URL}/time`);
        timestamp = await timeRes.text();
        fastify.log.info({ clobTime: timestamp }, 'Using CLOB server time');
      } catch {
        timestamp = Math.floor(Date.now() / 1000).toString();
        fastify.log.warn('Failed to get CLOB time, using local time');
      }

      const domain = {
        name: 'ClobAuthDomain',
        version: '1',
        chainId: POLYGON_CHAIN_ID,
      };

      const types = {
        ClobAuth: [
          { name: 'address', type: 'address' },
          { name: 'timestamp', type: 'string' },
          { name: 'nonce', type: 'uint256' },
          { name: 'message', type: 'string' },
        ],
      };

      const message = {
        address: body.walletAddress,
        timestamp,
        nonce: 0,
        message: 'This message attests that I control the given wallet',
      };

      return reply.send({ domain, types, message, timestamp });
    },
  );

  /**
   * POST /auth/submit-clob-auth
   * Submit signed ClobAuth to derive Polymarket L2 API key.
   */
  fastify.post(
    '/submit-clob-auth',
    { preHandler: [fastify.authenticate] },
    async (request: FastifyRequest, reply: FastifyReply) => {
      const { userId } = request.user;
      const body = request.body as {
        walletAddress: string;
        signature: string;
        timestamp: string;
      };

      if (!body.walletAddress || !body.signature || !body.timestamp) {
        return reply.status(400).send({ error: 'walletAddress, signature, and timestamp are required' });
      }

      fastify.log.info({ walletAddress: body.walletAddress }, 'POST /submit-clob-auth — deriving API key');

      try {
        const l1Headers = {
          'POLY_ADDRESS': body.walletAddress,
          'POLY_SIGNATURE': body.signature,
          'POLY_TIMESTAMP': body.timestamp,
          'POLY_NONCE': '0',
        };

        // Try derive first (existing wallet), then create (new wallet)
        let creds: any;
        const deriveRes = await fetch(`${POLYMARKET_CLOB_URL}/auth/derive-api-key`, {
          method: 'GET',
          headers: l1Headers,
        });

        if (deriveRes.ok) {
          creds = await deriveRes.json();
          fastify.log.info('derive-api-key succeeded');
        } else {
          const deriveErr = await deriveRes.text();
          fastify.log.info({ status: deriveRes.status, body: deriveErr }, 'derive-api-key failed, trying create-api-key...');

          const createRes = await fetch(`${POLYMARKET_CLOB_URL}/auth/api-key`, {
            method: 'POST',
            headers: { ...l1Headers, 'Content-Type': 'application/json' },
          });

          if (!createRes.ok) {
            const createErr = await createRes.text();
            fastify.log.error({ status: createRes.status, body: createErr }, 'create-api-key also failed');
            return reply.status(createRes.status).send({ error: `Polymarket API key creation failed: ${createErr}` });
          }

          creds = await createRes.json();
          fastify.log.info('create-api-key succeeded');
        }
        // Normalize field names — Polymarket returns 'apiKey', ClobClient expects 'key'
        const normalizedCreds = {
          key: creds.apiKey || creds.key,
          secret: creds.secret,
          passphrase: creds.passphrase,
        };
        fastify.log.info({ hasKey: !!normalizedCreds.key }, 'Credentials normalized — storing');

        // Store L2 credentials in Redis (24h TTL)
        await fastify.redis.set(
          `clob_creds:${body.walletAddress}`,
          JSON.stringify(normalizedCreds),
          'EX',
          86400,
        );

        // Upsert user_wallets row
        const existingWallet = await fastify.db.query.userWallets.findFirst({
          where: eq(userWallets.userId, userId),
        });

        if (existingWallet) {
          await fastify.db
            .update(userWallets)
            .set({
              walletAddress: body.walletAddress,
              delegationStatus: 'active',
              updatedAt: new Date(),
            })
            .where(eq(userWallets.id, existingWallet.id));
        } else {
          await fastify.db.insert(userWallets).values({
            userId,
            walletAddress: body.walletAddress,
            dynamicWalletId: 'embedded', // client-side signing, no delegation wallet ID
            encryptedKeyShare: Buffer.from(''), // not used for client-side signing
            encryptedWalletApiKey: Buffer.from(''),
            encryptionIv: Buffer.from(''),
            encryptionTag: Buffer.from(''),
            delegationStatus: 'active',
            delegatedAt: new Date(),
          });
        }

        return reply.send({ success: true, walletAddress: body.walletAddress });
      } catch (err) {
        fastify.log.error({ err }, 'POST /submit-clob-auth — FAILED');
        throw new AppError('Failed to derive CLOB API key', 500);
      }
    },
  );

  /**
   * POST /auth/delegation-webhook
   * Receive delegation materials from Dynamic webhook.
   */
  fastify.post('/delegation-webhook', async (request: FastifyRequest, reply: FastifyReply) => {
    fastify.log.info({ headers: Object.keys(request.headers), body: typeof request.body }, 'Delegation webhook received');

    // TODO: Re-enable signature verification in production
    // For now, skip signature check during development
    // const signature = request.headers['x-dynamic-signature-256'] as string | undefined;

    // Handle ping messages from Dynamic
    const rawBody = request.body as any;
    if (!rawBody?.eventName || rawBody?.eventName !== 'wallet.delegation.created') {
      fastify.log.info({ eventName: rawBody?.eventName }, 'Webhook ping/non-delegation event — OK');
      return reply.send({ success: true });
    }

    let payload;
    try {
      payload = delegationWebhookSchema.parse(request.body);
    } catch (parseErr) {
      fastify.log.error({ parseErr, body: JSON.stringify(request.body).substring(0, 500) }, 'Webhook payload parse failed');
      return reply.status(400).send({ error: 'Invalid payload' });
    }

    // Idempotency: check if we already processed this event
    const idempotencyKey = `delegation:event:${payload.eventId}`;
    const alreadyProcessed = await fastify.redis.get(idempotencyKey);
    if (alreadyProcessed) {
      return reply.send({ success: true, message: 'Already processed' });
    }

    fastify.log.info({
      eventId: payload.eventId,
      walletId: payload.data.walletId,
      publicKey: payload.data.publicKey,
      dynamicUserId: payload.data.userId,
      topLevelUserId: (payload as any).userId,
      chain: payload.data.chain,
    }, 'Delegation webhook — parsed payload');

    // Decrypt delegation materials (HYBRID-RSA-AES-256)
    const privateKeyPem = fastify.config.DYNAMIC_RSA_PRIVATE_KEY;
    let decryptedDelegatedShare: any;
    let decryptedWalletApiKey: string;
    try {
      decryptedDelegatedShare = JSON.parse(
        decryptHybridRsaAes(privateKeyPem, payload.data.encryptedDelegatedShare),
      );
      decryptedWalletApiKey = decryptHybridRsaAes(
        privateKeyPem,
        payload.data.encryptedWalletApiKey,
      );
      fastify.log.info('Delegation webhook — decryption successful');
    } catch (decryptErr) {
      fastify.log.error({ decryptErr }, 'Delegation webhook — DECRYPTION FAILED');
      return reply.status(500).send({ error: 'Decryption failed' });
    }

    // Find user by Dynamic user ID (may be null in some webhook versions)
    const dynamicUserId = payload.data.userId || payload.userId;
    let user;

    fastify.log.info({ dynamicUserId }, 'Delegation webhook — looking up user');

    if (dynamicUserId) {
      user = await fastify.db.query.users.findFirst({
        where: eq(users.dynamicUserId, dynamicUserId),
      });
      fastify.log.info({ found: !!user, dynamicUserId }, 'Delegation webhook — lookup by dynamicUserId');
    }

    // Fallback: find by wallet address
    if (!user && payload.data.publicKey) {
      const { userWallets } = await import('../../db/schema.js');
      const existingWallet = await fastify.db.query.userWallets.findFirst({
        where: eq(userWallets.walletAddress, payload.data.publicKey),
      });
      if (existingWallet) {
        user = await fastify.db.query.users.findFirst({
          where: eq(users.id, existingWallet.userId),
        });
      }
    }

    // Last resort: find most recently created user
    if (!user) {
      const { desc } = await import('drizzle-orm');
      user = await fastify.db.query.users.findFirst({
        orderBy: (users, { desc }) => [desc(users.createdAt)],
      });
    }

    if (!user) {
      fastify.log.warn(`Delegation webhook: no user found. dynamicUserId=${dynamicUserId}, publicKey=${payload.data.publicKey}`);
      return reply.status(404).send({ error: 'User not found' });
    }

    fastify.log.info(`Delegation webhook matched user: ${user.id} (${user.email})`);

    // Store encrypted at rest
    await storeDelegationMaterials(
      fastify,
      user.id,
      payload.data.walletId,
      payload.data.publicKey,
      decryptedDelegatedShare,
      decryptedWalletApiKey,
    );

    // Mark as processed (24h TTL)
    await fastify.redis.set(idempotencyKey, '1', 'EX', 86400);

    fastify.log.info(`Delegation stored for user ${user.id}, wallet ${payload.data.walletId}`);

    return reply.send({ success: true });
  });
}
