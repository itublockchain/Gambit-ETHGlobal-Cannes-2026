import { ClobClient, Side, OrderType } from '@polymarket/clob-client';
import type { ApiKeyCreds } from '@polymarket/clob-client';
import { createPublicClient, http, type PublicClient } from 'viem';
import { polygon } from 'viem/chains';
import { POLYMARKET_CLOB_URL, POLYGON_CHAIN_ID } from '../../config.js';
import type { DelegationCredentials } from '../../types/dynamic.js';
import {
  createDelegatedEvmWalletClient,
  delegatedSignTypedData,
} from '@dynamic-labs-wallet/node-evm';
import type { FastifyInstance } from 'fastify';

let _publicClient: PublicClient | null = null;

function getPublicClient(): PublicClient {
  if (!_publicClient) {
    _publicClient = createPublicClient({
      chain: polygon,
      transport: http('https://polygon-bor-rpc.publicnode.com'),
    });
  }
  return _publicClient;
}

/**
 * Create an EthersSigner-compatible wrapper around Dynamic's delegated signing.
 * ClobClient uses _signTypedData and getAddress.
 */
function createDelegatedClobSigner(
  environmentId: string,
  apiKey: string,
  credentials: DelegationCredentials,
) {
  const delegatedClient = createDelegatedEvmWalletClient({ environmentId, apiKey });

  return {
    async getAddress(): Promise<string> {
      return credentials.walletAddress;
    },

    async _signTypedData(
      domain: Record<string, unknown>,
      types: Record<string, Array<{ name: string; type: string }>>,
      value: Record<string, unknown>,
    ): Promise<string> {
      // Find primaryType — it's the type that's NOT EIP712Domain
      const primaryType = Object.keys(types).find((t) => t !== 'EIP712Domain') || 'ClobAuth';

      const signature = await delegatedSignTypedData(delegatedClient, {
        walletId: credentials.walletId,
        walletApiKey: credentials.walletApiKey,
        keyShare: credentials.keyShare,
        typedData: { domain, types, message: value, primaryType } as any,
      });
      return signature;
    },
  };
}

/**
 * Create a ClobClient with delegated signing for a user.
 * Handles L2 credential derivation and caching.
 */
export async function createUserClobClient(
  fastify: FastifyInstance,
  credentials: DelegationCredentials,
): Promise<ClobClient> {
  const signer = createDelegatedClobSigner(
    fastify.config.DYNAMIC_ENVIRONMENT_ID,
    fastify.config.DYNAMIC_API_KEY,
    credentials,
  );

  // Check for cached L2 credentials
  const cacheKey = `clob_creds:${credentials.walletAddress}`;
  const cached = await fastify.redis.get(cacheKey);

  let creds: ApiKeyCreds | undefined;
  if (cached) {
    creds = JSON.parse(cached);
  }

  const client = new ClobClient(
    POLYMARKET_CLOB_URL,
    POLYGON_CHAIN_ID,
    signer as any,
    creds,
    0, // SignatureType: EOA — Dynamic MPC delegation produces standard ECDSA signatures
    undefined, // funderAddress
    undefined, // geoBlockToken
    true, // useServerTime
  );

  // Derive and cache L2 credentials if not cached
  if (!creds) {
    fastify.log.info('Deriving CLOB L2 API credentials...');
    let derivedCreds;
    try {
      derivedCreds = await client.createOrDeriveApiKey();
    } catch {
      // createApiKey can fail, try deriveApiKey directly
      fastify.log.info('createApiKey failed, trying deriveApiKey...');
      derivedCreds = await client.deriveApiKey();
    }
    await fastify.redis.set(cacheKey, JSON.stringify(derivedCreds), 'EX', 86400);
    fastify.log.info('CLOB L2 credentials derived and cached');

    // Re-create client with credentials
    return new ClobClient(
      POLYMARKET_CLOB_URL,
      POLYGON_CHAIN_ID,
      signer as any,
      derivedCreds,
      0, // EOA
      undefined,
      undefined,
      true,
    );
  }

  return client;
}

export { getPublicClient };
