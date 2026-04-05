import Fastify from 'fastify';
import cors from '@fastify/cors';
import { createPublicClient, createWalletClient, http, parseAbi, formatUnits, defineChain } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import WS from 'ws';

// Arc Testnet chain definition
const arcTestnet = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.arc.network'] } },
  blockExplorers: { default: { name: 'ArcScan', url: 'https://testnet.arcscan.app' } },
});

const CONTRACT = '0xfE3dd8F80051B2F3da054F8657BaF016478697bD' as const;
const USDC_ERC20 = '0x3600000000000000000000000000000000000000' as const;

const MARKET_ABI = parseAbi([
  'function createMarket(string asset, uint256 strikePrice, uint48 duration) returns (uint256)',
  'function placeBet(uint256 marketId, uint8 direction, uint256 amount)',
  'function settleMarket(uint256 marketId, uint256 finalPrice)',
  'function claim(uint256 marketId)',
  'function requestSettlement(uint256 marketId)',
  'function getMarket(uint256 marketId) view returns (string asset, uint256 strikePrice, uint256 finalPrice, uint48 startTime, uint48 endTime, bool settled, uint8 outcome, uint256 totalUpPool, uint256 totalDownPool)',
  'function getPosition(uint256 marketId, address user) view returns (uint256 amount, uint8 direction, bool claimed)',
  'function nextMarketId() view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
]);

// Spot prices cache
const spotPrices: Record<string, number> = {};

// Active markets cache
const activeMarkets: Map<string, { marketId: bigint; asset: string; strikePrice: bigint; endTime: number }> = new Map();

async function start() {
  const PRIVATE_KEY = process.env.PRIVATE_KEY;
  if (!PRIVATE_KEY) throw new Error('PRIVATE_KEY env required');

  const account = privateKeyToAccount(PRIVATE_KEY as `0x${string}`);

  const publicClient = createPublicClient({
    chain: arcTestnet,
    transport: http(),
  });

  const walletClient = createWalletClient({
    account,
    chain: arcTestnet,
    transport: http(),
  });

  const app = Fastify({ logger: { level: 'info' } });
  await app.register(cors, { origin: true });

  // --- Binance WS for live prices ---
  function connectBinance() {
    const symbols = ['btcusdt@trade', 'ethusdt@trade', 'xrpusdt@trade'];
    const ws = new WS(`wss://stream.binance.com:9443/ws/${symbols.join('/')}`);
    const map: Record<string, string> = { BTCUSDT: 'btc', ETHUSDT: 'eth', XRPUSDT: 'xrp' };

    ws.on('open', () => app.log.info('Binance WS connected'));
    ws.on('message', (data: Buffer) => {
      try {
        const msg = JSON.parse(data.toString()) as { s: string; p: string };
        const asset = map[msg.s];
        if (asset) spotPrices[asset] = parseFloat(msg.p);
      } catch {}
    });
    ws.on('close', () => { app.log.info('Binance WS closed'); setTimeout(connectBinance, 2000); });
    ws.on('error', () => {});
  }

  // --- Market rotation: create 5-min markets ---
  async function createNewMarkets() {
    for (const asset of ['btc', 'eth', 'xrp']) {
      const price = spotPrices[asset];
      if (!price) continue;

      // Strike price with 8 decimals
      const strikePrice = BigInt(Math.round(price * 100000000));

      try {
        const hash = await walletClient.writeContract({
          address: CONTRACT,
          abi: MARKET_ABI,
          functionName: 'createMarket',
          args: [asset, strikePrice, 300], // 5 minutes
        });

        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        const nextId = await publicClient.readContract({
          address: CONTRACT,
          abi: MARKET_ABI,
          functionName: 'nextMarketId',
        });
        const marketId = nextId - 1n;

        activeMarkets.set(asset, {
          marketId,
          asset,
          strikePrice,
          endTime: Math.floor(Date.now() / 1000) + 300,
        });

        app.log.info(`Market created: ${asset} #${marketId} @ ${price}`);
      } catch (err) {
        app.log.error(`Failed to create ${asset} market: ${(err as Error).message}`);
      }
    }
  }

  // --- Auto-settle expired markets ---
  async function settleExpiredMarkets() {
    const now = Math.floor(Date.now() / 1000);
    for (const [asset, market] of activeMarkets) {
      if (now >= market.endTime && spotPrices[asset]) {
        const finalPrice = BigInt(Math.round(spotPrices[asset] * 100000000));
        try {
          await walletClient.writeContract({
            address: CONTRACT,
            abi: MARKET_ABI,
            functionName: 'settleMarket',
            args: [market.marketId, finalPrice],
          });
          app.log.info(`Settled ${asset} #${market.marketId}: ${spotPrices[asset]}`);
          activeMarkets.delete(asset);
        } catch (err) {
          app.log.error(`Settle failed ${asset}: ${(err as Error).message}`);
        }
      }
    }
  }

  // --- API Routes ---

  app.get('/health', async () => ({ status: 'ok', chain: 'arc-testnet' }));

  // GET /api/v1/markets/active — active markets + prices
  app.get('/api/v1/markets/active', async () => {
    const markets = [];
    for (const [asset, m] of activeMarkets) {
      markets.push({
        marketId: m.marketId.toString(),
        asset: m.asset,
        strikePrice: Number(m.strikePrice) / 100000000,
        endTime: m.endTime,
        spotPrice: spotPrices[asset] || null,
        timeRemaining: Math.max(0, m.endTime - Math.floor(Date.now() / 1000)),
      });
    }
    return { markets, spotPrices };
  });

  // GET /api/v1/markets/stream — SSE price stream
  app.get('/api/v1/markets/stream', async (request, reply) => {
    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });

    const interval = setInterval(() => {
      const data = JSON.stringify({ spotPrices, t: Date.now() });
      reply.raw.write(`data: ${data}\n\n`);
    }, 500);

    request.raw.on('close', () => clearInterval(interval));
  });

  // POST /api/v1/orders — place a bet
  app.post('/api/v1/orders', async (request, reply) => {
    const body = request.body as { asset: string; direction: string; amount: number };
    const market = activeMarkets.get(body.asset);
    if (!market) return reply.status(400).send({ error: 'No active market for ' + body.asset });

    const direction = body.direction === 'up' ? 0 : 1;
    const amount = BigInt(Math.round(body.amount * 1000000)); // 6 decimals for USDC ERC-20

    try {
      const hash = await walletClient.writeContract({
        address: CONTRACT,
        abi: MARKET_ABI,
        functionName: 'placeBet',
        args: [market.marketId, direction, amount],
      });

      return reply.status(201).send({
        orderId: hash,
        marketId: market.marketId.toString(),
        asset: body.asset,
        direction: body.direction,
        amount: body.amount,
        status: 'confirmed',
      });
    } catch (err) {
      return reply.status(400).send({ error: (err as Error).message });
    }
  });

  // GET /api/v1/wallet/balances — USDC balance on Arc
  app.get('/api/v1/wallet/balances', async () => {
    try {
      const balance = await publicClient.readContract({
        address: USDC_ERC20,
        abi: parseAbi(['function balanceOf(address) view returns (uint256)']),
        functionName: 'balanceOf',
        args: [account.address],
      });

      const usdce = formatUnits(balance, 6);
      return {
        usdc: '0',
        usdce,
        pol: '0',
        total: usdce,
        walletAddress: account.address,
      };
    } catch {
      return { usdc: '0', usdce: '0', pol: '0', total: '0', walletAddress: account.address };
    }
  });

  // --- Start ---
  const port = parseInt(process.env.PORT || '3002');
  await app.listen({ port, host: '0.0.0.0' });
  app.log.info(`Arc backend running on http://0.0.0.0:${port}`);

  // Start Binance WS
  connectBinance();

  // Wait for prices, then create initial markets
  setTimeout(async () => {
    await createNewMarkets();
  }, 3000);

  // Rotate markets every 4 minutes + settle expired
  setInterval(async () => {
    await settleExpiredMarkets();
    await createNewMarkets();
  }, 240000);

  // Check for expired markets every 10s
  setInterval(settleExpiredMarkets, 10000);
}

start();
