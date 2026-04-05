import {
  createDelegatedEvmWalletClient,
  delegatedSignTransaction,
  delegatedSignMessage,
} from '@dynamic-labs-wallet/node-evm';
import type { TransactionSerializable } from 'viem';
import type { DelegationCredentials } from '../../types/dynamic.js';

let _client: ReturnType<typeof createDelegatedEvmWalletClient> | null = null;

/**
 * Get or create the singleton delegated wallet client.
 */
export function getDelegatedClient(environmentId: string, apiKey: string) {
  if (!_client) {
    _client = createDelegatedEvmWalletClient({
      environmentId,
      apiKey,
    });
  }
  return _client;
}

/**
 * Sign a transaction using delegated MPC access.
 */
export async function signTransaction(
  environmentId: string,
  apiKey: string,
  credentials: DelegationCredentials,
  transaction: TransactionSerializable,
): Promise<string> {
  const client = getDelegatedClient(environmentId, apiKey);

  return delegatedSignTransaction(client, {
    walletId: credentials.walletId,
    walletApiKey: credentials.walletApiKey,
    keyShare: credentials.keyShare,
    transaction,
  });
}

/**
 * Sign a message using delegated MPC access.
 * Used for EIP-712 typed data signing (CLOB L1/L2 auth).
 */
export async function signMessage(
  environmentId: string,
  apiKey: string,
  credentials: DelegationCredentials,
  message: string,
): Promise<string> {
  const client = getDelegatedClient(environmentId, apiKey);

  return delegatedSignMessage(client, {
    walletId: credentials.walletId,
    walletApiKey: credentials.walletApiKey,
    keyShare: credentials.keyShare,
    message,
  });
}
