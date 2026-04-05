import type { FastifyInstance } from 'fastify';
import { encodeFunctionData, parseAbi, maxUint256 } from 'viem';
import { getDelegationCredentials } from '../../lib/dynamic/delegation.js';
import { signTransaction } from '../../lib/dynamic/wallet-client.js';
import { getPublicClient } from '../../lib/polymarket/clob-client.js';

const POLYGON_RPC = 'https://polygon-bor-rpc.publicnode.com';
const USDC_ADDRESS = '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359' as const;
const USDC_E_ADDRESS = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174' as const;
const CTF_EXCHANGE = '0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E' as const;
// QuickSwap V3 SwapRouter on Polygon
const QUICKSWAP_ROUTER = '0xf5b509bB0909a69B1c207E495f687a596C168E12' as const;

const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
]);

/**
 * Fetch all token balances for a wallet via RPC.
 */
export async function getWalletBalances(walletAddress: string): Promise<{
  usdc: string;
  usdce: string;
  pol: string;
  total: string;
}> {
  const callData = (tokenAddress: string) =>
    `0x70a08231000000000000000000000000${walletAddress.slice(2)}`;

  const [usdcRes, usdceRes, polRes] = await Promise.all([
    rpcCall(tokenAddress(USDC_ADDRESS), callData(USDC_ADDRESS)),
    rpcCall(tokenAddress(USDC_E_ADDRESS), callData(USDC_E_ADDRESS)),
    rpcBalanceCall(walletAddress),
  ]);

  const usdc = parseBalance(usdcRes, 6);
  const usdce = parseBalance(usdceRes, 6);
  const pol = parseBalance(polRes, 18);

  return {
    usdc: usdc.toFixed(2),
    usdce: usdce.toFixed(2),
    pol: pol.toFixed(4),
    total: (usdc + usdce).toFixed(2),
  };
}

/**
 * Auto-swap USDC native → USDC.e + approve for CTF Exchange.
 * Called periodically by cron.
 */
export async function autoSwapAndApprove(fastify: FastifyInstance): Promise<void> {
  const wallet = await fastify.db.query.userWallets.findFirst({
    where: (w, { eq }) => eq(w.delegationStatus, 'active'),
  });
  if (!wallet) return;

  const balances = await getWalletBalances(wallet.walletAddress);
  const usdcBalance = parseFloat(balances.usdc);

  // Swap USDC → USDC.e if USDC balance > $0.50
  if (usdcBalance > 0.5) {
    fastify.log.info(`Auto-swapping ${usdcBalance} USDC → USDC.e`);
    try {
      const credentials = await getDelegationCredentials(fastify, wallet.userId);
      await swapUSDCtoUSDCe(fastify, credentials, usdcBalance);
      fastify.log.info('Swap complete');
    } catch (err) {
      fastify.log.error({ err: (err as Error).message }, 'Auto-swap failed');
    }
  }

  // Ensure USDC.e is approved for CTF Exchange
  try {
    const credentials = await getDelegationCredentials(fastify, wallet.userId);
    await ensureApproval(fastify, credentials, USDC_E_ADDRESS, CTF_EXCHANGE);
  } catch (err) {
    fastify.log.error({ err: (err as Error).message }, 'Auto-approve failed');
  }
}

/**
 * Swap USDC native to USDC.e using QuickSwap on Polygon.
 */
async function swapUSDCtoUSDCe(
  fastify: FastifyInstance,
  credentials: Awaited<ReturnType<typeof getDelegationCredentials>>,
  amount: number,
): Promise<void> {
  const publicClient = getPublicClient();
  const walletAddress = credentials.walletAddress as `0x${string}`;
  const amountRaw = BigInt(Math.floor(amount * 1e6));

  // 1. Approve USDC for QuickSwap router
  await ensureApproval(fastify, credentials, USDC_ADDRESS, QUICKSWAP_ROUTER);

  // 2. Swap via QuickSwap exactInputSingle
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 300);
  const swapData = encodeFunctionData({
    abi: parseAbi([
      'function exactInputSingle((address tokenIn, address tokenOut, address recipient, uint256 deadline, uint256 amountIn, uint256 amountOutMinimum, uint160 limitSqrtPrice)) returns (uint256)',
    ]),
    functionName: 'exactInputSingle',
    args: [{
      tokenIn: USDC_ADDRESS,
      tokenOut: USDC_E_ADDRESS,
      recipient: walletAddress,
      deadline,
      amountIn: amountRaw,
      amountOutMinimum: amountRaw * BigInt(99) / BigInt(100), // 1% slippage
      limitSqrtPrice: BigInt(0),
    }],
  });

  const nonce = await publicClient.getTransactionCount({ address: walletAddress });
  const gasPrice = await publicClient.getGasPrice();

  const signedTx = await signTransaction(
    fastify.config.DYNAMIC_ENVIRONMENT_ID,
    fastify.config.DYNAMIC_API_KEY,
    credentials,
    {
      to: QUICKSWAP_ROUTER,
      data: swapData,
      value: BigInt(0),
      chainId: 137,
      nonce,
      gas: BigInt(300000),
      maxFeePerGas: gasPrice * BigInt(2),
      maxPriorityFeePerGas: BigInt(30000000000),
    },
  );

  const txHash = await publicClient.sendRawTransaction({
    serializedTransaction: signedTx as `0x${string}`,
  });
  fastify.log.info(`Swap TX: ${txHash}`);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
}

/**
 * Ensure a token is approved for a spender.
 */
async function ensureApproval(
  fastify: FastifyInstance,
  credentials: Awaited<ReturnType<typeof getDelegationCredentials>>,
  tokenAddress: `0x${string}`,
  spenderAddress: `0x${string}`,
): Promise<void> {
  const walletAddress = credentials.walletAddress as `0x${string}`;

  // Check current allowance
  const allowanceData = encodeFunctionData({
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: [walletAddress, spenderAddress],
  });

  const result = await rpcCall(tokenAddress, `${allowanceData}`);
  const allowance = BigInt(result || '0x0');

  // If allowance is already high enough, skip
  if (allowance > BigInt(1e12)) return;

  fastify.log.info(`Approving ${tokenAddress} for ${spenderAddress}...`);
  const publicClient = getPublicClient();

  const approveData = encodeFunctionData({
    abi: ERC20_ABI,
    functionName: 'approve',
    args: [spenderAddress, maxUint256],
  });

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

  const txHash = await publicClient.sendRawTransaction({
    serializedTransaction: signedTx as `0x${string}`,
  });
  fastify.log.info(`Approve TX: ${txHash}`);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
}

/**
 * Withdraw USDC.e (or USDC) to an external address.
 */
export async function withdrawFunds(
  fastify: FastifyInstance,
  userId: string,
  toAddress: string,
  amount: number,
  token: 'usdc' | 'usdce' = 'usdce',
): Promise<{ txHash: string; amount: string }> {
  const credentials = await getDelegationCredentials(fastify, userId);
  const publicClient = getPublicClient();
  const walletAddress = credentials.walletAddress as `0x${string}`;
  const tokenAddr = token === 'usdce' ? USDC_E_ADDRESS : USDC_ADDRESS;
  const amountRaw = BigInt(Math.floor(amount * 1e6));

  const transferData = encodeFunctionData({
    abi: ERC20_ABI,
    functionName: 'transfer',
    args: [toAddress as `0x${string}`, amountRaw],
  });

  const nonce = await publicClient.getTransactionCount({ address: walletAddress });
  const gasPrice = await publicClient.getGasPrice();

  const signedTx = await signTransaction(
    fastify.config.DYNAMIC_ENVIRONMENT_ID,
    fastify.config.DYNAMIC_API_KEY,
    credentials,
    {
      to: tokenAddr,
      data: transferData,
      value: BigInt(0),
      chainId: 137,
      nonce,
      gas: BigInt(100000),
      maxFeePerGas: gasPrice * BigInt(2),
      maxPriorityFeePerGas: BigInt(30000000000),
    },
  );

  const txHash = await publicClient.sendRawTransaction({
    serializedTransaction: signedTx as `0x${string}`,
  });

  fastify.log.info(`Withdraw TX: ${txHash} — ${amount} ${token} to ${toAddress}`);
  await publicClient.waitForTransactionReceipt({ hash: txHash });

  return { txHash, amount: amount.toFixed(2) };
}

// --- RPC helpers ---

function tokenAddress(addr: string): string {
  return addr;
}

async function rpcCall(to: string, data: string): Promise<string> {
  const res = await fetch(POLYGON_RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0', method: 'eth_call',
      params: [{ to, data }, 'latest'], id: 1,
    }),
  });
  const json = (await res.json()) as { result: string };
  return json.result;
}

async function rpcBalanceCall(address: string): Promise<string> {
  const res = await fetch(POLYGON_RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0', method: 'eth_getBalance',
      params: [address, 'latest'], id: 1,
    }),
  });
  const json = (await res.json()) as { result: string };
  return json.result;
}

function parseBalance(hex: string, decimals: number): number {
  if (!hex || hex === '0x') return 0;
  return parseInt(hex, 16) / Math.pow(10, decimals);
}
