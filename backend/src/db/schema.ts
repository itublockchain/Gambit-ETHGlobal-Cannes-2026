import {
  pgTable,
  uuid,
  varchar,
  text,
  timestamp,
  decimal,
  boolean,
  integer,
  customType,
  index,
} from 'drizzle-orm/pg-core';

// Custom bytea type for encrypted data
const bytea = customType<{ data: Buffer }>({
  dataType() {
    return 'bytea';
  },
});

// ── Users ──────────────────────────────────────────────────────────────

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  dynamicUserId: varchar('dynamic_user_id', { length: 255 }).notNull().unique(),
  email: varchar('email', { length: 255 }),
  displayName: varchar('display_name', { length: 255 }),
  defaultBetAmount: decimal('default_bet_amount', { precision: 10, scale: 2 }).default('5.00'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
});

// ── User Wallets (delegation credentials) ──────────────────────────────

export const userWallets = pgTable(
  'user_wallets',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    walletAddress: varchar('wallet_address', { length: 42 }).notNull(),
    dynamicWalletId: varchar('dynamic_wallet_id', { length: 255 }).notNull(),
    // Encrypted delegation materials (AES-256-GCM)
    encryptedKeyShare: bytea('encrypted_key_share').notNull(),
    encryptedWalletApiKey: bytea('encrypted_wallet_api_key').notNull(),
    encryptionIv: bytea('encryption_iv').notNull(),
    encryptionTag: bytea('encryption_tag').notNull(),
    delegationStatus: varchar('delegation_status', { length: 20 }).notNull().default('pending'),
    delegatedAt: timestamp('delegated_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [index('idx_user_wallets_user').on(table.userId)],
);

// ── Orders ─────────────────────────────────────────────────────────────

export const orders = pgTable(
  'orders',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id),
    clobOrderId: varchar('clob_order_id', { length: 255 }),
    tokenId: varchar('token_id', { length: 255 }).notNull(),
    conditionId: varchar('condition_id', { length: 255 }).notNull(),
    marketSlug: varchar('market_slug', { length: 255 }),
    side: varchar('side', { length: 4 }).notNull(), // BUY | SELL
    orderType: varchar('order_type', { length: 4 }).notNull().default('FOK'), // GTC | GTD | FOK | FAK
    price: decimal('price', { precision: 10, scale: 4 }).notNull(),
    size: decimal('size', { precision: 18, scale: 6 }).notNull(),
    filledSize: decimal('filled_size', { precision: 18, scale: 6 }).notNull().default('0'),
    status: varchar('status', { length: 20 }).notNull().default('pending'),
    outcome: varchar('outcome', { length: 4 }), // UP | DOWN
    errorMessage: text('error_message'),
    placedAt: timestamp('placed_at', { withTimezone: true }),
    filledAt: timestamp('filled_at', { withTimezone: true }),
    cancelledAt: timestamp('cancelled_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index('idx_orders_user_status').on(table.userId, table.status),
    index('idx_orders_clob_id').on(table.clobOrderId),
  ],
);

// ── Positions ──────────────────────────────────────────────────────────

export const positions = pgTable(
  'positions',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id),
    tokenId: varchar('token_id', { length: 255 }).notNull(),
    conditionId: varchar('condition_id', { length: 255 }).notNull(),
    marketSlug: varchar('market_slug', { length: 255 }),
    outcome: varchar('outcome', { length: 4 }).notNull(), // UP | DOWN
    size: decimal('size', { precision: 18, scale: 6 }).notNull(),
    avgPrice: decimal('avg_price', { precision: 10, scale: 4 }).notNull(),
    realizedPnl: decimal('realized_pnl', { precision: 18, scale: 6 }).notNull().default('0'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [index('idx_positions_user').on(table.userId)],
);

// ── Audit Log (append-only) ────────────────────────────────────────────

export const auditLog = pgTable(
  'audit_log',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id),
    action: varchar('action', { length: 50 }).notNull(),
    payloadHash: varchar('payload_hash', { length: 64 }),
    success: boolean('success').notNull(),
    errorMessage: text('error_message'),
    latencyMs: integer('latency_ms'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [index('idx_audit_user_date').on(table.userId, table.createdAt)],
);
