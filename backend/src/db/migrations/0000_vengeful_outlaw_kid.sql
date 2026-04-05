CREATE TABLE "audit_log" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"action" varchar(50) NOT NULL,
	"payload_hash" varchar(64),
	"success" boolean NOT NULL,
	"error_message" text,
	"latency_ms" integer,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "orders" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"clob_order_id" varchar(255),
	"token_id" varchar(255) NOT NULL,
	"condition_id" varchar(255) NOT NULL,
	"market_slug" varchar(255),
	"side" varchar(4) NOT NULL,
	"order_type" varchar(4) DEFAULT 'FOK' NOT NULL,
	"price" numeric(10, 4) NOT NULL,
	"size" numeric(18, 6) NOT NULL,
	"filled_size" numeric(18, 6) DEFAULT '0' NOT NULL,
	"status" varchar(20) DEFAULT 'pending' NOT NULL,
	"outcome" varchar(4),
	"error_message" text,
	"placed_at" timestamp with time zone,
	"filled_at" timestamp with time zone,
	"cancelled_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "positions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"token_id" varchar(255) NOT NULL,
	"condition_id" varchar(255) NOT NULL,
	"market_slug" varchar(255),
	"outcome" varchar(4) NOT NULL,
	"size" numeric(18, 6) NOT NULL,
	"avg_price" numeric(10, 4) NOT NULL,
	"realized_pnl" numeric(18, 6) DEFAULT '0' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "user_wallets" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"wallet_address" varchar(42) NOT NULL,
	"dynamic_wallet_id" varchar(255) NOT NULL,
	"encrypted_key_share" "bytea" NOT NULL,
	"encrypted_wallet_api_key" "bytea" NOT NULL,
	"encryption_iv" "bytea" NOT NULL,
	"encryption_tag" "bytea" NOT NULL,
	"delegation_status" varchar(20) DEFAULT 'pending' NOT NULL,
	"delegated_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "users" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"dynamic_user_id" varchar(255) NOT NULL,
	"email" varchar(255),
	"display_name" varchar(255),
	"default_bet_amount" numeric(10, 2) DEFAULT '5.00',
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "users_dynamic_user_id_unique" UNIQUE("dynamic_user_id")
);
--> statement-breakpoint
ALTER TABLE "audit_log" ADD CONSTRAINT "audit_log_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "orders" ADD CONSTRAINT "orders_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "positions" ADD CONSTRAINT "positions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_wallets" ADD CONSTRAINT "user_wallets_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "idx_audit_user_date" ON "audit_log" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "idx_orders_user_status" ON "orders" USING btree ("user_id","status");--> statement-breakpoint
CREATE INDEX "idx_orders_clob_id" ON "orders" USING btree ("clob_order_id");--> statement-breakpoint
CREATE INDEX "idx_positions_user" ON "positions" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "idx_user_wallets_user" ON "user_wallets" USING btree ("user_id");