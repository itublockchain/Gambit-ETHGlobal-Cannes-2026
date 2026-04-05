import {
  Runner,
  handler,
  EVMClient,
  HTTPClient,
  getNetwork,
  hexToBase64,
  bytesToHex,
  consensusIdenticalAggregation,
  type Runtime,
  type NodeRuntime,
  type EVMLog,
} from "@chainlink/cre-sdk";
import { encodeAbiParameters, parseAbiParameters, keccak256, toHex } from "viem";

// Config loaded from config.staging.json
type Config = {
  marketAddress: string;
  chainSelectorName: string;
  gasLimit: string;
};

// SettlementRequested(uint256 indexed marketId, string asset, uint256 strikePrice, uint48 endTime)
const SETTLEMENT_EVENT_HASH = keccak256(
  toHex("SettlementRequested(uint256,string,uint256,uint48)")
);

/**
 * Fetch current BTC price from Binance (runs in node mode for offchain data).
 */
const fetchPrice = (nodeRuntime: NodeRuntime<Config>): string => {
  const httpClient = new HTTPClient();
  const resp = httpClient
    .sendRequest(nodeRuntime, {
      url: "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT",
      method: "GET" as const,
    })
    .result();
  return new TextDecoder().decode(resp.body);
};

/**
 * Log Trigger callback: When SettlementRequested is emitted,
 * fetch price from Binance and settle the market on-chain.
 */
const onSettlementRequested = (runtime: Runtime<Config>, log: EVMLog): string => {
  // Decode marketId from indexed topic
  const marketIdHex = bytesToHex(log.topics[1]?.value || new Uint8Array(32));
  const marketId = BigInt(marketIdHex);

  runtime.log(`Settlement requested for market ${marketId}`);

  // Fetch price via Binance (offchain, needs node consensus)
  const priceJson = runtime
    .runInNodeMode(fetchPrice, consensusIdenticalAggregation())()
    .result() as string;

  const priceData = JSON.parse(priceJson);
  const finalPrice = BigInt(Math.round(parseFloat(priceData.price) * 100000000));

  runtime.log(`Final price: ${priceData.price} (raw: ${finalPrice})`);

  // Encode settleMarket(uint256 marketId, uint256 finalPrice)
  const reportData = encodeAbiParameters(
    parseAbiParameters("uint256, uint256"),
    [marketId, finalPrice]
  );

  // Generate signed report
  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(reportData),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result();

  // Get EVM client for Arc
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: runtime.config.chainSelectorName,
  });
  if (!network) throw new Error("Network not found");
  const evmClient = new EVMClient(network.chainSelector.selector);

  // Write settlement to contract
  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: runtime.config.marketAddress,
      report: reportResponse,
      gasConfig: { gasLimit: runtime.config.gasLimit },
    })
    .result();

  const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32));
  runtime.log(`Market ${marketId} settled. TX: ${txHash}`);

  return txHash;
};

/**
 * Initialize workflow: register log trigger for SettlementRequested events.
 */
const initWorkflow = (config: Config) => {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: config.chainSelectorName,
  });
  if (!network) throw new Error("Network not found");
  const evmClient = new EVMClient(network.chainSelector.selector);

  return [
    handler(
      evmClient.logTrigger({
        addresses: [hexToBase64(config.marketAddress as `0x${string}`)],
        topics: [
          { values: [hexToBase64(SETTLEMENT_EVENT_HASH)] },
        ],
      }),
      onSettlementRequested
    ),
  ];
};

// Required entry point
export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
