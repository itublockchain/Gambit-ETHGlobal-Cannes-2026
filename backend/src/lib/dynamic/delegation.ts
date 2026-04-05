import crypto from 'node:crypto';
import type { DelegationCredentials, EncryptedHybridData } from '../../types/dynamic.js';
import type { FastifyInstance } from 'fastify';
import { eq } from 'drizzle-orm';
import { userWallets } from '../../db/schema.js';
import { DelegationError } from '../errors.js';

/**
 * Decrypt HYBRID-RSA-AES-256 encrypted data from Dynamic webhook.
 * Scheme: RSA-OAEP encrypts a random AES-256-GCM content encryption key (CEK).
 * The CEK is used to encrypt the actual payload.
 *
 * Fields: alg, ek (encrypted key, base64url), iv (base64url), ct (ciphertext, base64url), tag (base64url)
 */
export function decryptHybridRsaAes(
  privateKeyPem: string,
  encrypted: EncryptedHybridData,
): string {
  // 1. Decode base64url fields
  const ek = Buffer.from(encrypted.ek, 'base64url');
  const iv = Buffer.from(encrypted.iv, 'base64url');
  const ct = Buffer.from(encrypted.ct, 'base64url');
  const tag = Buffer.from(encrypted.tag, 'base64url');

  // 2. Decrypt the content encryption key (CEK) with RSA-OAEP
  const cek = crypto.privateDecrypt(
    {
      key: privateKeyPem,
      padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
      oaepHash: 'sha256',
    },
    ek,
  );

  // 3. Decrypt the ciphertext with AES-256-GCM
  const decipher = crypto.createDecipheriv('aes-256-gcm', cek, iv);
  decipher.setAuthTag(tag);
  const decrypted = Buffer.concat([decipher.update(ct), decipher.final()]);

  return decrypted.toString('utf8');
}

/**
 * Encrypt delegation materials for storage using AES-256-GCM.
 * The ENCRYPTION_KEY from env is used as the key.
 */
export function encryptForStorage(
  data: string,
  encryptionKey: string,
): { encrypted: Buffer; iv: Buffer; tag: Buffer } {
  const key = Buffer.from(encryptionKey, 'hex');
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);

  const encrypted = Buffer.concat([cipher.update(data, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();

  return { encrypted, iv, tag };
}

/**
 * Decrypt delegation materials from storage.
 */
export function decryptFromStorage(
  encrypted: Buffer,
  iv: Buffer,
  tag: Buffer,
  encryptionKey: string,
): string {
  const key = Buffer.from(encryptionKey, 'hex');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);

  return decipher.update(encrypted) + decipher.final('utf8');
}

/**
 * Store decrypted delegation materials encrypted at rest.
 */
export async function storeDelegationMaterials(
  fastify: FastifyInstance,
  userId: string,
  walletId: string,
  walletAddress: string,
  decryptedKeyShare: unknown,
  decryptedWalletApiKey: string,
): Promise<void> {
  const encryptionKey = fastify.config.ENCRYPTION_KEY;

  const keyShareJson = JSON.stringify(decryptedKeyShare);
  const keyShareEncrypted = encryptForStorage(keyShareJson, encryptionKey);
  const apiKeyEncrypted = encryptForStorage(decryptedWalletApiKey, encryptionKey);

  // Combine IVs and tags (both use the same structure)
  const combinedIv = Buffer.concat([keyShareEncrypted.iv, apiKeyEncrypted.iv]);
  const combinedTag = Buffer.concat([keyShareEncrypted.tag, apiKeyEncrypted.tag]);

  // Delete any existing wallet for this user, then insert fresh
  await fastify.db.delete(userWallets).where(eq(userWallets.userId, userId));

  await fastify.db.insert(userWallets).values({
    userId,
    walletAddress,
    dynamicWalletId: walletId,
    encryptedKeyShare: keyShareEncrypted.encrypted,
    encryptedWalletApiKey: apiKeyEncrypted.encrypted,
    encryptionIv: combinedIv,
    encryptionTag: combinedTag,
    delegationStatus: 'active',
    delegatedAt: new Date(),
  });
}

/**
 * Retrieve and decrypt delegation credentials for a user.
 */
export async function getDelegationCredentials(
  fastify: FastifyInstance,
  userId: string,
): Promise<DelegationCredentials> {
  const wallet = await fastify.db.query.userWallets.findFirst({
    where: eq(userWallets.userId, userId),
  });

  if (!wallet || wallet.delegationStatus !== 'active') {
    throw new DelegationError('No active delegation found for user');
  }

  const encryptionKey = fastify.config.ENCRYPTION_KEY;

  // Split combined IVs and tags (each 16 bytes)
  const keyShareIv = wallet.encryptionIv.subarray(0, 16);
  const apiKeyIv = wallet.encryptionIv.subarray(16, 32);
  const keyShareTag = wallet.encryptionTag.subarray(0, 16);
  const apiKeyTag = wallet.encryptionTag.subarray(16, 32);

  const keyShareJson = decryptFromStorage(
    wallet.encryptedKeyShare,
    keyShareIv,
    keyShareTag,
    encryptionKey,
  );

  const walletApiKey = decryptFromStorage(
    wallet.encryptedWalletApiKey,
    apiKeyIv,
    apiKeyTag,
    encryptionKey,
  );

  return {
    walletId: wallet.dynamicWalletId,
    walletAddress: wallet.walletAddress,
    walletApiKey,
    keyShare: JSON.parse(keyShareJson),
  };
}
