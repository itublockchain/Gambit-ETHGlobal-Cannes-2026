import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { eq } from 'drizzle-orm';
import { getWalletBalances, withdrawFunds } from './wallet.service.js';
import { userWallets } from '../../db/schema.js';
import { z } from 'zod';
import { encodeFunctionData, parseAbi, maxUint256, createPublicClient, http, serializeTransaction, keccak256, type TransactionSerializableEIP1559 } from 'viem';
import { polygon } from 'viem/chains';

const withdrawSchema = z.object({
  toAddress: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  amount: z.number().positive(),
  token: z.enum(['usdc', 'usdce']).default('usdce'),
});

export default async function walletRoutes(fastify: FastifyInstance) {
  /**
   * GET /wallet/balances
   * Real-time wallet balances — requires JWT auth.
   */
  fastify.get('/balances', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const { userId } = request.user;
    const wallet = await fastify.db.query.userWallets.findFirst({
      where: eq(userWallets.userId, userId),
    });

    if (!wallet) {
      return reply.send({ usdc: '0', usdce: '0', pol: '0', total: '0', walletAddress: null });
    }

    const balances = await getWalletBalances(wallet.walletAddress);
    return reply.send({ ...balances, walletAddress: wallet.walletAddress });
  });

  /**
   * GET /wallet/balances/stream
   * SSE stream for real-time balance updates.
   * Auth via ?token=<jwt> query param (SSE doesn't support custom headers).
   */
  fastify.get('/balances/stream', async (request: FastifyRequest, reply: FastifyReply) => {
    // Verify JWT from query param
    const { token } = request.query as { token?: string };
    if (!token) {
      return reply.status(401).send({ error: 'Unauthorized' });
    }

    let userId: string;
    try {
      const decoded = fastify.jwt.verify<{ userId: string }>(token);
      userId = decoded.userId;
    } catch {
      return reply.status(401).send({ error: 'Invalid token' });
    }

    const wallet = await fastify.db.query.userWallets.findFirst({
      where: eq(userWallets.userId, userId),
    });

    if (!wallet) {
      return reply.send({ error: 'No wallet' });
    }

    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no',
    });

    // Send balances every 5 seconds
    const interval = setInterval(async () => {
      try {
        const balances = await getWalletBalances(wallet.walletAddress);
        reply.raw.write(`data: ${JSON.stringify({ ...balances, walletAddress: wallet.walletAddress })}\n\n`);
      } catch {}
    }, 5000);

    // Immediate first send
    const balances = await getWalletBalances(wallet.walletAddress);
    reply.raw.write(`data: ${JSON.stringify({ ...balances, walletAddress: wallet.walletAddress })}\n\n`);

    request.raw.on('close', () => clearInterval(interval));
  });

  /**
   * POST /wallet/permit-data
   * Build EIP-2612 permit typed data for client-side signing (no on-chain tx needed from user).
   */
  fastify.post('/permit-data', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as { walletAddress: string };
    if (!body.walletAddress) {
      return reply.status(400).send({ error: 'walletAddress required' });
    }

    const CTF_EXCHANGE = '0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E' as `0x${string}`;
    const USDC_E = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174' as `0x${string}`;
    const walletAddr = body.walletAddress as `0x${string}`;
    const publicClient = createPublicClient({ chain: polygon, transport: http('https://polygon-bor-rpc.publicnode.com') });

    // Check if already approved
    const allowance = await publicClient.readContract({
      address: USDC_E,
      abi: parseAbi(['function allowance(address owner, address spender) view returns (uint256)']),
      functionName: 'allowance',
      args: [walletAddr, CTF_EXCHANGE],
    });

    if (allowance > BigInt(1e12)) {
      return reply.send({ alreadyApproved: true, permits: [] });
    }

    // Get permit nonce
    const nonce = await publicClient.readContract({
      address: USDC_E,
      abi: parseAbi(['function nonces(address owner) view returns (uint256)']),
      functionName: 'nonces',
      args: [walletAddr],
    });

    // Get DOMAIN_SEPARATOR components (USDC.e on Polygon)
    const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour

    const permitData = {
      domain: {
        name: 'USD Coin (PoS)',
        version: '1',
        verifyingContract: USDC_E,
        salt: '0x0000000000000000000000000000000000000000000000000000000000000089', // chainId 137 as bytes32
      },
      types: {
        Permit: [
          { name: 'owner', type: 'address' },
          { name: 'spender', type: 'address' },
          { name: 'value', type: 'uint256' },
          { name: 'nonce', type: 'uint256' },
          { name: 'deadline', type: 'uint256' },
        ],
      },
      message: {
        owner: body.walletAddress,
        spender: CTF_EXCHANGE,
        value: '115792089237316195423570985008687907853269984665640564039457584007913129639935', // max uint256
        nonce: nonce.toString(),
        deadline: deadline.toString(),
      },
      deadline,
    };

    return reply.send({ alreadyApproved: false, permits: [{ token: 'USDC.e', ...permitData }] });
  });

  /**
   * POST /wallet/submit-permit
   * Submit a signed EIP-2612 permit to the blockchain.
   */
  fastify.post('/submit-permit', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as {
      walletAddress: string;
      spender: string;
      value: string;
      deadline: string;
      signature: string;
      token: string;
    };

    const USDC_E = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174' as `0x${string}`;
    const publicClient = createPublicClient({ chain: polygon, transport: http('https://polygon-bor-rpc.publicnode.com') });

    // Parse signature into v, r, s
    const sig = body.signature.startsWith('0x') ? body.signature.slice(2) : body.signature;
    const r = `0x${sig.slice(0, 64)}` as `0x${string}`;
    const s = `0x${sig.slice(64, 128)}` as `0x${string}`;
    let v = parseInt(sig.slice(128, 130), 16);
    if (v < 27) v += 27;

    // Call permit on USDC.e contract
    const permitData = encodeFunctionData({
      abi: parseAbi(['function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)']),
      functionName: 'permit',
      args: [
        body.walletAddress as `0x${string}`,
        body.spender as `0x${string}`,
        BigInt(body.value),
        BigInt(body.deadline),
        v,
        r,
        s,
      ],
    });

    // Anyone can submit the permit tx — we do it from backend
    // Use a simple eth_call to estimate, then send raw
    const gasPrice = await publicClient.getGasPrice();

    // We need a funded wallet to submit the permit tx. Use the user's own wallet?
    // Actually, permit needs to be called on-chain. Let's use eth_sendTransaction via a relay.
    // Simpler: just call the contract directly via the user's next tx.
    // For now, store the permit signature and use it with the first order.

    // Store permit in Redis for use during order submission
    await fastify.redis.set(
      `permit:${body.walletAddress}:${USDC_E}`,
      JSON.stringify({ v, r, s, deadline: body.deadline, value: body.value }),
      'EX',
      3600,
    );

    fastify.log.info(`Permit stored for ${body.walletAddress}`);
    return reply.send({ success: true });
  });

  /**
   * POST /wallet/approve-hash
   * Build approve tx, return the hash for signing + serialized unsigned tx.
   */
  fastify.post('/approve-hash', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as { walletAddress: string };
    if (!body.walletAddress) return reply.status(400).send({ error: 'walletAddress required' });

    const CTF_EXCHANGE = '0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E' as `0x${string}`;
    const USDC_E = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174' as `0x${string}`;
    const USDC = '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359' as `0x${string}`;
    const walletAddr = body.walletAddress as `0x${string}`;

    const publicClient = createPublicClient({ chain: polygon, transport: http('https://polygon-bor-rpc.publicnode.com') });
    const approveData = encodeFunctionData({
      abi: parseAbi(['function approve(address spender, uint256 amount) returns (bool)']),
      functionName: 'approve',
      args: [CTF_EXCHANGE, maxUint256],
    });

    const txs: any[] = [];
    let nonce = await publicClient.getTransactionCount({ address: walletAddr });
    const gasPrice = await publicClient.getGasPrice();

    for (const [name, tokenAddr] of [['USDC.e', USDC_E], ['USDC', USDC]] as const) {
      // Check allowance
      try {
        const allowance = await publicClient.readContract({
          address: tokenAddr,
          abi: parseAbi(['function allowance(address owner, address spender) view returns (uint256)']),
          functionName: 'allowance',
          args: [walletAddr, CTF_EXCHANGE],
        });
        if (allowance > BigInt(1e12)) {
          fastify.log.info(`${name} already approved`);
          continue;
        }
      } catch {}

      const tx: TransactionSerializableEIP1559 = {
        to: tokenAddr,
        data: approveData,
        value: BigInt(0),
        chainId: 137,
        nonce: nonce++,
        gas: BigInt(100000),
        maxFeePerGas: gasPrice * BigInt(2),
        maxPriorityFeePerGas: BigInt(30000000000),
        type: 'eip1559',
      };

      const serialized = serializeTransaction(tx);
      const hash = keccak256(serialized);

      txs.push({
        token: name,
        to: tokenAddr,
        data: approveData,
        hash,
        serializedUnsigned: serialized,
        nonce: tx.nonce,
      });
    }

    return reply.send({ txs });
  });

  /**
   * POST /wallet/submit-approved
   * Attach signature to unsigned tx and broadcast.
   */
  fastify.post('/submit-approved', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as { serializedUnsigned: string; signature: string };

    const sig = body.signature.startsWith('0x') ? body.signature.slice(2) : body.signature;
    const r = `0x${sig.slice(0, 64)}` as `0x${string}`;
    const s = `0x${sig.slice(64, 128)}` as `0x${string}`;
    let v = parseInt(sig.slice(128, 130), 16);
    if (v >= 27) v -= 27; // EIP-1559 uses yParity (0 or 1)

    // Re-serialize with signature
    // For EIP-1559: type 2, the signed serialization is 0x02 || rlp([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, yParity, r, s])
    // We need to parse the unsigned tx and add the signature
    const publicClient = createPublicClient({ chain: polygon, transport: http('https://polygon-bor-rpc.publicnode.com') });

    // The serialized unsigned tx + signature forms the raw signed tx
    // viem's serializeTransaction can do this if we pass the signature
    const { parseTransaction } = await import('viem');
    const unsignedTx = parseTransaction(body.serializedUnsigned as `0x${string}`);

    const signedSerialized = serializeTransaction(
      { ...unsignedTx, type: 'eip1559' } as TransactionSerializableEIP1559,
      { r, s, yParity: v as 0 | 1 },
    );

    const txHash = await publicClient.sendRawTransaction({ serializedTransaction: signedSerialized });
    fastify.log.info(`Approve TX broadcast: ${txHash}`);
    await publicClient.waitForTransactionReceipt({ hash: txHash });

    return reply.send({ txHash });
  });

  /**
   * POST /wallet/approve-txs
   * Build unsigned USDC approval transactions for client-side signing.
   */
  fastify.post('/approve-txs', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as { walletAddress: string };
    if (!body.walletAddress) {
      return reply.status(400).send({ error: 'walletAddress required' });
    }

    const CTF_EXCHANGE = '0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E' as `0x${string}`;
    const USDC = '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359' as `0x${string}`;
    const USDC_E = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174' as `0x${string}`;

    const approveData = encodeFunctionData({
      abi: parseAbi(['function approve(address spender, uint256 amount) returns (bool)']),
      functionName: 'approve',
      args: [CTF_EXCHANGE, maxUint256],
    });

    const publicClient = createPublicClient({ chain: polygon, transport: http('https://polygon-bor-rpc.publicnode.com') });
    const walletAddr = body.walletAddress as `0x${string}`;

    const txs: { token: string; rawTx: string }[] = [];

    for (const [name, tokenAddr] of [['USDC', USDC], ['USDC.e', USDC_E]] as const) {
      // Check if already approved
      try {
        const allowance = await publicClient.readContract({
          address: tokenAddr,
          abi: parseAbi(['function allowance(address owner, address spender) view returns (uint256)']),
          functionName: 'allowance',
          args: [walletAddr, CTF_EXCHANGE],
        });
        if (allowance > BigInt(1e12)) {
          fastify.log.info(`${name} already approved — skipping`);
          continue;
        }
      } catch {}

      txs.push({
        token: name,
        to: tokenAddr,
        data: approveData,
      });
    }

    return reply.send(txs);
  });

  /**
   * POST /wallet/send-raw-tx
   * Broadcast a signed transaction to Polygon.
   */
  fastify.post('/send-raw-tx', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body as { signedTx: string };
    if (!body.signedTx) {
      return reply.status(400).send({ error: 'signedTx required' });
    }

    const publicClient = createPublicClient({ chain: polygon, transport: http('https://polygon-bor-rpc.publicnode.com') });

    try {
      const txHash = await publicClient.sendRawTransaction({
        serializedTransaction: body.signedTx as `0x${string}`,
      });
      fastify.log.info(`TX broadcast: ${txHash}`);
      await publicClient.waitForTransactionReceipt({ hash: txHash });
      return reply.send({ txHash });
    } catch (err) {
      fastify.log.error({ err }, 'TX broadcast failed');
      return reply.status(500).send({ error: (err as Error).message });
    }
  });

  /**
   * POST /wallet/withdraw-data
   * Build withdraw tx data for client-side signing.
   */
  fastify.post('/withdraw-data', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    const { userId } = request.user;
    const body = withdrawSchema.parse(request.body);

    const wallet = await fastify.db.query.userWallets.findFirst({
      where: eq(userWallets.userId, userId),
    });
    if (!wallet?.walletAddress) return reply.status(400).send({ error: 'No wallet' });

    const USDC_E = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174';
    const USDC = '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359';
    const tokenAddr = body.token === 'usdce' ? USDC_E : USDC;
    const amountRaw = BigInt(Math.floor(body.amount * 1e6));

    const data = encodeFunctionData({
      abi: parseAbi(['function transfer(address to, uint256 amount) returns (bool)']),
      functionName: 'transfer',
      args: [body.toAddress as `0x${string}`, amountRaw],
    });

    return reply.send({ to: tokenAddr, data, amount: body.amount.toFixed(2), token: body.token });
  });

  /**
   * POST /wallet/withdraw (legacy)
   */
  fastify.post('/withdraw', { preHandler: [fastify.authenticate] }, async (request: FastifyRequest, reply: FastifyReply) => {
    return reply.status(400).send({ error: 'Use /wallet/withdraw-data with client-side signing' });
  });
}
