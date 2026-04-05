export interface DelegationCredentials {
  walletId: string;
  walletAddress: string;
  walletApiKey: string;
  keyShare: ServerKeyShare;
}

export interface ServerKeyShare {
  pubkey: { pubkey: Uint8Array };
  secretShare: string;
}

export interface EncryptedHybridData {
  alg: string;
  iv: string;
  ct: string;
  tag: string;
  ek: string;
  kid?: string;
}

export interface DelegationWebhookData {
  chain: string;
  encryptedDelegatedShare: EncryptedHybridData;
  encryptedWalletApiKey: EncryptedHybridData;
  publicKey: string;
  userId: string;
  walletId: string;
}
