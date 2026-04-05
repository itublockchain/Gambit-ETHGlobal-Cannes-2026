import { z } from 'zod';

export const verifyTokenSchema = z.object({
  dynamicJwt: z.string().min(1),
});

export const delegationWebhookSchema = z.object({
  messageId: z.string(),
  eventId: z.string(),
  eventName: z.literal('wallet.delegation.created'),
  timestamp: z.string(),
  webhookId: z.string(),
  userId: z.string().nullable().optional(),
  environmentId: z.string(),
  environmentName: z.string().optional(),
  data: z.object({
    chain: z.string(),
    encryptedDelegatedShare: z.object({
      alg: z.string(),
      iv: z.string(),
      ct: z.string(),
      tag: z.string(),
      ek: z.string(),
    }),
    encryptedWalletApiKey: z.object({
      alg: z.string(),
      iv: z.string(),
      ct: z.string(),
      tag: z.string(),
      ek: z.string(),
      kid: z.string().optional(),
    }),
    publicKey: z.string(),
    userId: z.string().nullable().optional(),
    walletId: z.string(),
  }),
});

export const delegationRevokedSchema = z.object({
  eventName: z.literal('wallet.delegation.revoked'),
  data: z.object({
    userId: z.string(),
    walletId: z.string(),
  }),
});

export type VerifyTokenInput = z.infer<typeof verifyTokenSchema>;
export type DelegationWebhookPayload = z.infer<typeof delegationWebhookSchema>;
