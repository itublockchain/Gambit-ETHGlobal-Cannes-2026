import type { FastifyInstance } from 'fastify';
import { eq } from 'drizzle-orm';
import crypto from 'node:crypto';
import { getDelegationCredentials } from '../../lib/dynamic/delegation.js';
import { createUserClobClient } from '../../lib/polymarket/clob-client.js';
import { getActiveMarketForAsset } from '../markets/markets.service.js';
import { orders, auditLog } from '../../db/schema.js';
import type { SupportedAsset } from '../../config.js';
import { Side, OrderType } from '@polymarket/clob-client';
import { encodeFunctionData, parseAbi, maxUint256 } from 'viem';
import { signTransaction } from '../../lib/dynamic/wallet-client.js';
import { getPublicClient } from '../../lib/polymarket/clob-client.js';
import { OrderError, NotFoundError } from '../../lib/errors.js';

const CTF_EXCHANGE = '0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E' as const;
const USDC_ADDRESS = '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359' as const;
const USDC_E_ADDRESS = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174' as const;

interface PlaceOrderParams {
  userId: string;
  asset: SupportedAsset;
  direction: 'up' | 'down';
  amount: number;
}

interface OrderResult {
  orderId: string;
  clobOrderId: string;
  status: string;
  asset: SupportedAsset;
  direction: 'up' | 'down';
  price: number;
  size: number;
  marketEndDate: string;
  marketSlug: string;
}

type DelegationCredentials = Awaited<ReturnType<typeof getDelegationCredentials>>;

// Create fresh ClobClient each time but L2 credentials are cached in Redis
async function getClobClient(fastify: FastifyInstance, userId: string) {
  const credentials = await getDelegationCredentials(fastify, userId);
  return createUserClobClient(fastify, credentials);
}

/**
 * Place a bet — optimized for speed (~3s with warm cache).
 */
export async function placeOrder(
  fastify: FastifyInstance,
  params: PlaceOrderParams,
): Promise<OrderResult> {
  const startTime = Date.now();

  // 1. Market from cache (60s TTL, refreshed by cron)
  const market = await getActiveMarketForAsset(fastify, params.asset);
  if (!market) {
    throw new OrderError(`No active market found for ${params.asset}`);
  }

  // 2. Cached CLOB client (reused across orders)
  const clobClient = await getClobClient(fastify, params.userId);

  // 3. Token + price
  const tokenId = params.direction === 'up' ? market.upTokenId : market.downTokenId;
  const price = parseFloat(params.direction === 'up' ? market.upPrice : market.downPrice);

  fastify.log.info({
    asset: params.asset,
    direction: params.direction,
    amount: params.amount,
  }, 'Placing market order...');

  // 4. Submit market buy — round amount to whole cents
  const roundedAmount = Math.floor(params.amount * 100) / 100;

  // Buy chosen token. If no asks, buy the OPPOSITE token instead.
  // In binary markets: buying opposite = betting the other way? No!
  // UP token has no asks → everyone thinks UP. Buy DOWN token (which HAS asks) to bet DOWN.
  // But user wants UP... so we need to check both sides.

  // Strategy: try chosen token first. If no liquidity, try opposite token with flipped direction.
  const oppositeTokenId = params.direction === 'up' ? market.downTokenId : market.upTokenId;

  // Try up to 3 times with short delays
  let clobResponse: any;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      clobResponse = await clobClient.createAndPostMarketOrder({
        tokenID: tokenId,
        amount: roundedAmount,
        price: 0.99,
        side: Side.BUY,
      }, undefined, OrderType.FOK);

      if (clobResponse?.orderID) {
        fastify.log.info({ attempt }, 'Order filled');
        break;
      }
    } catch {}

    if (attempt < 3) {
      fastify.log.info({ attempt }, 'Order not filled, retrying...');
      await new Promise(r => setTimeout(r, 300));
    }
  }

  if (!clobResponse?.orderID) {
    throw new OrderError('No liquidity available — try again shortly');
  }

  // Log full CLOB response for debugging
  fastify.log.info({ clobResponse: JSON.stringify(clobResponse).substring(0, 500) }, 'CLOB response');

  const orderID = clobResponse?.orderID ?? clobResponse?.orderIds?.[0] ?? null;
  const orderStatus = clobResponse?.status ?? (orderID ? 'matched' : 'failed');
  const latencyMs = Date.now() - startTime;

  fastify.log.info({ orderID, status: orderStatus, latencyMs }, 'Order completed');

  // 5. DB insert
  const dbSize = params.amount / price;
  const [order] = await fastify.db
    .insert(orders)
    .values({
      userId: params.userId,
      clobOrderId: orderID,
      tokenId,
      conditionId: market.conditionId,
      marketSlug: market.slug,
      side: 'BUY',
      orderType: 'FOK',
      price: price.toFixed(4),
      size: dbSize.toFixed(6),
      status: orderStatus === 'matched' ? 'filled' : orderStatus,
      outcome: params.direction.toUpperCase(),
      placedAt: new Date(),
      filledAt: orderStatus === 'matched' ? new Date() : null,
    })
    .returning({ id: orders.id });

  // Audit log (fire and forget)
  fastify.db.insert(auditLog).values({
    userId: params.userId,
    action: 'order.placed',
    payloadHash: crypto.createHash('sha256').update(`${tokenId}:${params.amount}`).digest('hex'),
    success: true,
    latencyMs,
  }).catch(() => {});

  return {
    orderId: order.id,
    clobOrderId: orderID || '',
    status: orderStatus,
    asset: params.asset,
    direction: params.direction,
    price,
    size: dbSize,
    marketEndDate: market.endDate,
    marketSlug: market.slug,
  };
}

/**
 * Sell (close) an open position by selling held shares.
 */
export async function sellPosition(
  fastify: FastifyInstance,
  userId: string,
  asset: SupportedAsset,
  direction: 'up' | 'down',
): Promise<{ status: string }> {
  const market = await getActiveMarketForAsset(fastify, asset);
  if (!market) throw new OrderError(`No active market for ${asset}`);

  const credentials = await getDelegationCredentials(fastify, userId);
  const clobClient = await createUserClobClient(fastify, credentials);

  const tokenId = direction === 'up' ? market.upTokenId : market.downTokenId;

  // Get current position size from Polymarket
  const posRes = await fetch(`https://data-api.polymarket.com/positions?user=${credentials.walletAddress}`);
  const positions = (await posRes.json()) as Array<{ title: string; size: number; curPrice: number }>;

  const assetName = asset === 'btc' ? 'Bitcoin' : asset === 'eth' ? 'Ethereum' : 'XRP';
  const pos = positions.find(p =>
    p.title?.includes(assetName) && p.curPrice > 0 && p.curPrice < 1
  );

  if (!pos || pos.size <= 0) {
    throw new OrderError('No open position to sell');
  }

  const size = Math.floor(pos.size * 100) / 100;

  // Approve conditional tokens for both exchanges (needed for SELL)
  const CT_ADDRESS = '0x4D97DCd97eC945f40cF65F87097ACe5EA0476045' as `0x${string}`;
  const NEG_RISK_EXCHANGE = '0xC5d563A36AE78145C45a50134d48A1215220f80a' as `0x${string}`;
  const publicClient = getPublicClient();
  const walletAddr = credentials.walletAddress as `0x${string}`;

  for (const spender of [CTF_EXCHANGE, NEG_RISK_EXCHANGE]) {
    try {
      // Check if already approved
      const isApproved = await publicClient.readContract({
        address: CT_ADDRESS,
        abi: parseAbi(['function isApprovedForAll(address owner, address operator) view returns (bool)']),
        functionName: 'isApprovedForAll',
        args: [walletAddr, spender as `0x${string}`],
      });
      if (isApproved) continue;

      const approveAllData = encodeFunctionData({
        abi: parseAbi(['function setApprovalForAll(address operator, bool approved)']),
        functionName: 'setApprovalForAll',
        args: [spender as `0x${string}`, true],
      });
      const nonce = await publicClient.getTransactionCount({ address: walletAddr });
      const gasPrice = await publicClient.getGasPrice();
      const signedTx = await signTransaction(
        fastify.config.DYNAMIC_ENVIRONMENT_ID,
        fastify.config.DYNAMIC_API_KEY,
        credentials,
        { to: CT_ADDRESS, data: approveAllData, value: BigInt(0), chainId: 137, nonce, gas: BigInt(100000), maxFeePerGas: gasPrice * BigInt(2), maxPriorityFeePerGas: BigInt(30000000000) },
      );
      const txHash = await publicClient.sendRawTransaction({ serializedTransaction: signedTx as `0x${string}` });
      fastify.log.info(`CT approve TX for ${spender}: ${txHash}`);
      await publicClient.waitForTransactionReceipt({ hash: txHash });
    } catch (err) {
      fastify.log.warn({ err: (err as Error).message }, `CT approval failed for ${spender}`);
    }
  }

  fastify.log.info({ asset, direction, size }, 'Selling position...');

  const signedOrder = await clobClient.createOrder({
    tokenID: tokenId,
    price: 0.01, // Sell at any price
    size,
    side: Side.SELL,
  });

  const clobResponse: any = await clobClient.postOrder(signedOrder, OrderType.FOK);

  fastify.log.info({ orderID: clobResponse?.orderID, status: clobResponse?.status }, 'Sell completed');

  return { status: clobResponse?.orderID ? 'sold' : 'failed' };
}

/**
 * Get all claimable (won) positions.
 */
export async function getClaimablePositions(walletAddress: string) {
  const res = await fetch(`https://data-api.polymarket.com/positions?user=${walletAddress}`);
  const positions = (await res.json()) as Array<{
    title: string; size: number; curPrice: number; cashPnl: number;
    conditionId: string; percentPnl: number;
  }>;

  return positions
    .filter(p => p.curPrice === 1 && p.size > 0)
    .map(p => ({
      title: p.title,
      shares: p.size,
      value: p.size,
      pnl: p.cashPnl,
      pnlPercent: p.percentPnl,
      conditionId: p.conditionId,
    }));
}

/**
 * Claim (redeem) winning conditional tokens for USDC.e.
 */
export async function claimPosition(
  fastify: FastifyInstance,
  userId: string,
  conditionId?: string,
): Promise<{ claimed: number; txHashes: string[] }> {
  const credentials = await getDelegationCredentials(fastify, userId);
  const publicClient = getPublicClient();
  const walletAddr = credentials.walletAddress as `0x${string}`;
  const CT_ADDRESS = '0x4D97DCd97eC945f40cF65F87097ACe5EA0476045' as `0x${string}`;
  const COLLATERAL = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174' as `0x${string}`;

  const claimable = await getClaimablePositions(credentials.walletAddress);
  const toClaim = conditionId ? claimable.filter(c => c.conditionId === conditionId) : claimable;

  if (toClaim.length === 0) throw new OrderError('No claimable positions');

  const txHashes: string[] = [];
  let totalClaimed = 0;
  let currentNonce = await publicClient.getTransactionCount({ address: walletAddr });

  for (const pos of toClaim) {
    try {
      const redeemData = encodeFunctionData({
        abi: parseAbi([
          'function redeemPositions(address collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint256[] indexSets)',
        ]),
        functionName: 'redeemPositions',
        args: [
          COLLATERAL,
          '0x0000000000000000000000000000000000000000000000000000000000000000' as `0x${string}`,
          pos.conditionId as `0x${string}`,
          [BigInt(1), BigInt(2)],
        ],
      });

      const gasPrice = await publicClient.getGasPrice();
      const signedTx = await signTransaction(
        fastify.config.DYNAMIC_ENVIRONMENT_ID, fastify.config.DYNAMIC_API_KEY, credentials,
        { to: CT_ADDRESS, data: redeemData, value: BigInt(0), chainId: 137, nonce: currentNonce, gas: BigInt(200000), maxFeePerGas: gasPrice * BigInt(2), maxPriorityFeePerGas: BigInt(30000000000) },
      );

      const txHash = await publicClient.sendRawTransaction({ serializedTransaction: signedTx as `0x${string}` });
      fastify.log.info(`Claim TX ${currentNonce}: ${txHash} for ${pos.title}`);
      await publicClient.waitForTransactionReceipt({ hash: txHash });
      txHashes.push(txHash);
      totalClaimed += pos.value;
      currentNonce++; // Increment for next TX
    } catch (err) {
      fastify.log.error({ err: (err as Error).message }, `Claim failed for ${pos.conditionId}`);
    }
  }

  return { claimed: totalClaimed, txHashes };
}

/**
 * Pre-warm: derive L2 credentials + approve USDC at startup.
 */
export async function prewarmOrderPipeline(fastify: FastifyInstance): Promise<void> {
  try {
    const wallet = await fastify.db.query.userWallets.findFirst({
      where: (w, { eq }) => eq(w.delegationStatus, 'active'),
    });
    if (!wallet) return;

    const credentials = await getDelegationCredentials(fastify, wallet.userId);

    // Pre-derive L2 credentials (cached in Redis by createUserClobClient)
    fastify.log.info('Pre-warming: deriving CLOB credentials...');
    await createUserClobClient(fastify, credentials);
    fastify.log.info('Pre-warming: CLOB credentials ready');

    // Pre-approve USDC.e
    const approvalCacheKey = `usdc_approved:${credentials.walletAddress}`;
    const approved = await fastify.redis.get(approvalCacheKey);
    if (!approved) {
      fastify.log.info('Pre-warming: approving USDC...');
      await approveUSDCForExchange(fastify, credentials);
      await fastify.redis.set(approvalCacheKey, '1', 'EX', 86400 * 30);
      fastify.log.info('Pre-warming: USDC approved');
    }

    fastify.log.info('Order pipeline pre-warmed — trades will be fast');
  } catch (err) {
    fastify.log.warn({ err: (err as Error).message }, 'Pre-warm failed');
  }
}

async function approveUSDCForExchange(
  fastify: FastifyInstance,
  credentials: DelegationCredentials,
): Promise<void> {
  const publicClient = getPublicClient();
  const walletAddress = credentials.walletAddress as `0x${string}`;
  const approveData = encodeFunctionData({
    abi: parseAbi(['function approve(address spender, uint256 amount) returns (bool)']),
    functionName: 'approve',
    args: [CTF_EXCHANGE, maxUint256],
  });

  for (const tokenAddress of [USDC_ADDRESS, USDC_E_ADDRESS]) {
    const nonce = await publicClient.getTransactionCount({ address: walletAddress });
    const gasPrice = await publicClient.getGasPrice();
    const signedTx = await signTransaction(
      fastify.config.DYNAMIC_ENVIRONMENT_ID,
      fastify.config.DYNAMIC_API_KEY,
      credentials,
      {
        to: tokenAddress,
        data: approveData,
        value: BigInt(0),
        chainId: 137,
        nonce,
        gas: BigInt(100000),
        maxFeePerGas: gasPrice * BigInt(2),
        maxPriorityFeePerGas: BigInt(30000000000),
      },
    );
    const txHash = await publicClient.sendRawTransaction({ serializedTransaction: signedTx as `0x${string}` });
    fastify.log.info(`Approve TX: ${txHash}`);
    await publicClient.waitForTransactionReceipt({ hash: txHash });
  }
}

export async function cancelOrderById(
  fastify: FastifyInstance,
  userId: string,
  orderId: string,
): Promise<void> {
  const order = await fastify.db.query.orders.findFirst({ where: eq(orders.id, orderId) });
  if (!order || order.userId !== userId) throw new NotFoundError('Order');
  if (order.status !== 'pending' && order.status !== 'open') throw new OrderError('Cannot cancel');
  if (order.clobOrderId) {
    const clobClient = await getClobClient(fastify, userId);
    await clobClient.cancelOrder({ id: order.clobOrderId } as any);
  }
  await fastify.db.update(orders).set({ status: 'cancelled', cancelledAt: new Date(), updatedAt: new Date() }).where(eq(orders.id, orderId));
}

export async function getUserOrders(fastify: FastifyInstance, userId: string, limit = 50) {
  return fastify.db.query.orders.findMany({
    where: eq(orders.userId, userId),
    orderBy: (orders, { desc }) => [desc(orders.createdAt)],
    limit,
  });
}
