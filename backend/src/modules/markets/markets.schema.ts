import { z } from 'zod';

export const activeMarketsQuerySchema = z.object({
  asset: z.enum(['btc', 'eth', 'xrp']).optional(),
});

export const marketPricesParamsSchema = z.object({
  conditionId: z.string().min(1),
});

export type ActiveMarketsQuery = z.infer<typeof activeMarketsQuerySchema>;
