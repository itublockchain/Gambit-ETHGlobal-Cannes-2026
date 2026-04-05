import { z } from 'zod';

export const placeOrderSchema = z.object({
  asset: z.enum(['btc', 'eth', 'xrp']),
  direction: z.enum(['up', 'down']),
  amount: z.number().positive().max(1000),
});

export const cancelOrderParamsSchema = z.object({
  orderId: z.string().min(1),
});

export type PlaceOrderInput = z.infer<typeof placeOrderSchema>;
