import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { eq } from 'drizzle-orm';
import crypto from 'node:crypto';
import { placeOrder, cancelOrderById, getUserOrders } from './orders.service.js';
import { placeOrderSchema, cancelOrderParamsSchema } from './orders.schema.js';
import { userWallets, orders, auditLog } from '../../db/schema.js';
import { getActiveMarketForAsset } from '../markets/markets.service.js';
import { POLYMARKET_CLOB_URL, POLYGON_CHAIN_ID } from '../../config.js';
import type { SupportedAsset } from '../../config.js';
import { OrderError, NotFoundError } from '../../lib/errors.js';
import { ClobClient, Side, OrderType } from '@polymarket/clob-client';
import type { ApiKeyCreds } from '@polymarket/clob-client';

export default async function ordersRoutes(fastify: FastifyInstance) {
  /**
   * POST /orders
   * Place a bet — requires JWT auth.
   */
  fastify.post('/', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = placeOrderSchema.parse(request.body);
    const { userId } = request.user;

    const result = await placeOrder(fastify, {
      userId,
      asset: body.asset,
      direction: body.direction,
      amount: body.amount,
    });

    return reply.status(201).send(result);
  });

  /**
   * GET /orders/claimable
   * Get all claimable (won) positions — requires JWT auth.
   */
  fastify.get('/claimable', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const { userId } = request.user;
    const wallet = await fastify.db.query.userWallets.findFirst({
      where: eq(userWallets.userId, userId),
    });
    if (!wallet) return reply.send({ claimable: [] });

    try {
      const { getClaimablePositions } = await import('./orders.service.js');
      const claimable = await getClaimablePositions(wallet.walletAddress);
      return reply.send({ claimable });
    } catch {
      return reply.send({ claimable: [] });
    }
  });

  /**
   * POST /orders/claim-data
   * Get redeem tx data for client-side signing.
   */
  fastify.post('/claim-data', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const { userId } = request.user;
    const body = request.body as { conditionId?: string };

    const wallet = await fastify.db.query.userWallets.findFirst({
      where: eq(userWallets.userId, userId),
    });
    if (!wallet?.walletAddress) return reply.status(400).send({ error: 'No wallet' });

    const { getClaimablePositions } = await import('./orders.service.js');
    const claimable = await getClaimablePositions(wallet.walletAddress);
    const toClaim = body.conditionId ? claimable.filter((c: any) => c.conditionId === body.conditionId) : claimable;

    if (toClaim.length === 0) return reply.send({ txs: [], totalValue: 0 });

    const CT_ADDRESS = '0x4D97DCd97eC945f40cF65F87097ACe5EA0476045';
    const COLLATERAL = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174';
    const { encodeFunctionData, parseAbi } = await import('viem');

    const txs = toClaim.map((pos: any) => {
      const data = encodeFunctionData({
        abi: parseAbi([
          'function redeemPositions(address collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint256[] indexSets)',
        ]),
        functionName: 'redeemPositions',
        args: [
          COLLATERAL as `0x${string}`,
          '0x0000000000000000000000000000000000000000000000000000000000000000' as `0x${string}`,
          pos.conditionId as `0x${string}`,
          [BigInt(1), BigInt(2)],
        ],
      });
      return { to: CT_ADDRESS, data, title: pos.title, value: pos.value, conditionId: pos.conditionId };
    });

    return reply.send({ txs, totalValue: toClaim.reduce((sum: number, p: any) => sum + p.value, 0) });
  });

  /**
   * POST /orders/claim (legacy redirect)
   */
  fastify.post('/claim', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    return reply.status(400).send({ error: 'Use /orders/claim-data with client-side signing' });
  });

  /**
   * POST /orders/sell-prepare
   * Prepare a sell order — returns EIP-712 typed data for signing.
   */
  fastify.post('/sell-prepare', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as { asset: string; direction: string };
    const { userId } = request.user;

    const wallet = await fastify.db.query.userWallets.findFirst({
      where: eq(userWallets.userId, userId),
    });
    if (!wallet?.walletAddress) throw new OrderError('No wallet found');

    const walletAddress = wallet.walletAddress;
    const asset = body.asset as SupportedAsset;

    const market = await getActiveMarketForAsset(fastify, asset);
    if (!market) throw new OrderError(`No active market for ${asset}`);

    const tokenId = body.direction === 'up' ? market.upTokenId : market.downTokenId;

    // Get position size from Polymarket
    const posRes = await fetch(`https://data-api.polymarket.com/positions?user=${walletAddress}`);
    const positions = (await posRes.json()) as Array<{ title: string; size: number; curPrice: number }>;
    const assetName = asset === 'btc' ? 'Bitcoin' : asset === 'eth' ? 'Ethereum' : 'XRP';
    const pos = positions.find(p => p.title?.includes(assetName) && p.curPrice > 0 && p.curPrice < 1);

    if (!pos || pos.size <= 0) throw new OrderError('No open position to sell');
    const size = Math.floor(pos.size * 100) / 100;

    // Get L2 credentials
    const credsRaw = await fastify.redis.get(`clob_creds:${walletAddress}`);
    if (!credsRaw) throw new OrderError('CLOB credentials not found');
    const creds = JSON.parse(credsRaw) as ApiKeyCreds;

    // Capture typed data for sell order
    let capturedTypedData: any = null;
    const captureSigner = {
      async getAddress() { return walletAddress; },
      async _signTypedData(domain: any, types: any, value: any) {
        capturedTypedData = { domain, types, message: value };
        return '0x' + '00'.repeat(65);
      },
    };

    const client = new ClobClient(
      POLYMARKET_CLOB_URL, POLYGON_CHAIN_ID,
      captureSigner as any, creds, 0,
      undefined, undefined, true,
    );

    try {
      await client.createOrder({
        tokenID: tokenId,
        price: 0.01,
        size,
        side: Side.SELL,
      });
    } catch {
      // Expected — dummy sig
    }

    if (!capturedTypedData) throw new OrderError('Failed to build sell order');

    const orderId = crypto.randomUUID();
    await fastify.redis.set(`pending_order:${orderId}`, JSON.stringify({
      userId, walletAddress, asset, direction: body.direction,
      amount: size, tokenId, price: 0.01,
      conditionId: market.conditionId, marketSlug: market.slug,
      endDate: market.endDate, signedOrder: capturedTypedData.message,
      isSell: true,
    }), 'EX', 300);

    fastify.log.info({ orderId, asset, direction: body.direction, size }, 'Sell order prepared');

    return reply.send({
      orderId,
      domain: capturedTypedData.domain,
      types: capturedTypedData.types,
      message: capturedTypedData.message,
      tokenId, price: 0.01, size,
      marketSlug: market.slug,
      endDate: market.endDate,
    });
  });

  /**
   * POST /orders/sell (legacy — redirects to prepare/submit flow)
   */
  fastify.post('/sell', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    return reply.status(400).send({ error: 'Use /orders/sell-prepare and /orders/submit-signed instead' });
  });

  /**
   * GET /orders
   * Get user's order history — requires JWT auth.
   */
  fastify.get('/', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const { userId } = request.user;
    const userOrders = await getUserOrders(fastify, userId);
    return reply.send({ orders: userOrders });
  });

  /**
   * DELETE /orders/:orderId
   * Cancel a pending order.
   */
  fastify.delete('/:orderId', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const params = cancelOrderParamsSchema.parse(request.params);
    const { userId } = request.user;

    await cancelOrderById(fastify, userId, params.orderId);
    return reply.send({ success: true });
  });

  /**
   * POST /orders/prepare
   * Use ClobClient to build order, capture typed data for iOS signing.
   */
  fastify.post('/prepare', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as { asset: string; direction: 'up' | 'down'; amount: number };
    const { userId } = request.user;

    if (!body.asset || !body.direction || !body.amount) {
      return reply.status(400).send({ error: 'asset, direction, and amount are required' });
    }

    const wallet = await fastify.db.query.userWallets.findFirst({
      where: eq(userWallets.userId, userId),
    });
    if (!wallet?.walletAddress) {
      throw new OrderError('No wallet found — complete CLOB auth first');
    }

    const walletAddress = wallet.walletAddress;
    const asset = body.asset as SupportedAsset;

    const market = await getActiveMarketForAsset(fastify, asset);
    if (!market) throw new OrderError(`No active market found for ${asset}`);

    const tokenId = body.direction === 'up' ? market.upTokenId : market.downTokenId;
    const price = parseFloat(body.direction === 'up' ? market.upPrice : market.downPrice);

    if (!price || isNaN(price)) throw new OrderError('Market price not available — try again');

    // Get L2 credentials
    const credsRaw = await fastify.redis.get(`clob_creds:${walletAddress}`);
    if (!credsRaw) throw new OrderError('CLOB credentials not found — re-authenticate');
    const creds = JSON.parse(credsRaw) as ApiKeyCreds;

    // Capture typed data from ClobClient's signer
    let capturedTypedData: any = null;
    const captureSigner = {
      async getAddress() { return walletAddress; },
      async _signTypedData(domain: any, types: any, value: any) {
        capturedTypedData = { domain, types, message: value };
        // Return dummy sig — we just want the typed data
        return '0x' + '00'.repeat(65);
      },
    };

    const client = new ClobClient(
      POLYMARKET_CLOB_URL, POLYGON_CHAIN_ID,
      captureSigner as any, creds, 0,
      undefined, undefined, true,
    );

    const roundedAmount = Math.floor(body.amount * 100) / 100;

    try {
      await client.createMarketOrder({
        tokenID: tokenId,
        amount: roundedAmount,
        price: 0.99,
        side: Side.BUY,
      });
    } catch (err) {
      // Expected if we captured typed data (dummy sig causes downstream error)
      // But log it in case it failed before reaching the signer
      fastify.log.info({ captured: !!capturedTypedData, err: (err as Error).message }, 'createMarketOrder result');
    }

    if (!capturedTypedData) {
      throw new OrderError('Failed to build order — could not capture typed data');
    }

    const orderId = crypto.randomUUID();
    const pendingOrder = {
      userId, walletAddress, asset,
      direction: body.direction, amount: body.amount,
      tokenId, price,
      conditionId: market.conditionId,
      marketSlug: market.slug,
      endDate: market.endDate,
      signedOrder: capturedTypedData.message, // Raw order fields from ClobClient
      negRisk: market.negRisk ?? false,
    };

    await fastify.redis.set(`pending_order:${orderId}`, JSON.stringify(pendingOrder), 'EX', 300);

    fastify.log.info({ orderId, asset, direction: body.direction, amount: body.amount, price }, 'Order prepared via ClobClient');

    return reply.send({
      orderId,
      domain: capturedTypedData.domain,
      types: capturedTypedData.types,
      message: capturedTypedData.message,
      tokenId, price,
      marketSlug: market.slug,
      endDate: market.endDate,
    });
  });

  /**
   * POST /orders/submit-signed
   * Submit client-signed order using ClobClient.postOrder.
   */
  fastify.post('/submit-signed', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const startTime = Date.now();
    const body = request.body as { orderId: string; signature: string };
    const { userId } = request.user;

    if (!body.orderId || !body.signature) {
      return reply.status(400).send({ error: 'orderId and signature are required' });
    }

    const pendingRaw = await fastify.redis.get(`pending_order:${body.orderId}`);
    if (!pendingRaw) throw new NotFoundError('Pending order not found or expired');

    const pending = JSON.parse(pendingRaw);
    if (pending.userId !== userId) throw new OrderError('Order does not belong to this user');

    const credsRaw = await fastify.redis.get(`clob_creds:${pending.walletAddress}`);
    if (!credsRaw) throw new OrderError('CLOB credentials not found');
    const creds = JSON.parse(credsRaw) as ApiKeyCreds;

    // Create ClobClient with a no-op signer (we won't sign, just post)
    const noopSigner = {
      async getAddress() { return pending.walletAddress; },
      async _signTypedData() { return '0x'; },
    };

    const client = new ClobClient(
      POLYMARKET_CLOB_URL, POLYGON_CHAIN_ID,
      noopSigner as any, creds, 0,
      undefined, undefined, true,
    );

    // Reconstruct signed order from captured fields + iOS signature
    const signedOrder = {
      ...pending.signedOrder,
      signature: body.signature,
    };

    fastify.log.info({ orderId: body.orderId, signedOrder: JSON.stringify(signedOrder).substring(0, 300) }, 'Posting signed order via ClobClient');

    try {
      const clobResponse: any = await client.postOrder(signedOrder, OrderType.FOK);
      const latencyMs = Date.now() - startTime;

      fastify.log.info({ orderID: clobResponse?.orderID, status: clobResponse?.status, latencyMs }, 'CLOB order response');

      const clobOrderId = clobResponse?.orderID ?? null;
      const orderStatus = clobResponse?.status ?? (clobOrderId ? 'matched' : 'failed');

      const dbSize = pending.amount / pending.price;
      const [dbOrder] = await fastify.db
        .insert(orders)
        .values({
          userId,
          clobOrderId,
          tokenId: pending.tokenId,
          conditionId: pending.conditionId,
          marketSlug: pending.marketSlug,
          side: 'BUY',
          orderType: 'FOK',
          price: pending.price.toFixed(4),
          size: dbSize.toFixed(6),
          status: orderStatus === 'matched' ? 'filled' : orderStatus,
          outcome: pending.direction.toUpperCase(),
          placedAt: new Date(),
          filledAt: orderStatus === 'matched' ? new Date() : null,
        })
        .returning({ id: orders.id });

      fastify.db.insert(auditLog).values({
        userId, action: 'order.signed_submit',
        payloadHash: crypto.createHash('sha256').update(`${pending.tokenId}:${pending.amount}`).digest('hex'),
        success: true, latencyMs,
      }).catch(() => {});

      await fastify.redis.del(`pending_order:${body.orderId}`);

      return reply.status(201).send({
        orderId: dbOrder.id,
        clobOrderId: clobOrderId || '',
        status: orderStatus,
        asset: pending.asset,
        direction: pending.direction,
        price: pending.price,
        size: dbSize,
        marketEndDate: pending.endDate,
        marketSlug: pending.marketSlug,
      });
    } catch (err) {
      fastify.log.error({ err: (err as Error).message }, 'submit-signed failed');
      throw new OrderError(`Order failed: ${(err as Error).message}`);
    }
  });
}
