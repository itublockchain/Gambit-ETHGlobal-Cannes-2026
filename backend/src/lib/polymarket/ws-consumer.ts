import WebSocket from 'ws';
import type Redis from 'ioredis';
import { POLYMARKET_WS_URL } from '../../config.js';

const PING_INTERVAL = 5000; // 5 seconds per Polymarket requirement
const RECONNECT_BASE_DELAY = 1000;
const MAX_RECONNECT_DELAY = 30000;

/**
 * Manages connection to Polymarket's CLOB WebSocket for real-time price data.
 * Publishes price updates to Redis pub/sub channels.
 */
export class PolymarketWSConsumer {
  private ws: WebSocket | null = null;
  private redis: Redis;
  private subscribedTokenIds = new Set<string>();
  private pingInterval: ReturnType<typeof setInterval> | null = null;
  private reconnectAttempts = 0;
  private isShuttingDown = false;
  private logger: { info: (...args: unknown[]) => void; error: (...args: unknown[]) => void };

  constructor(
    redis: Redis,
    logger: { info: (...args: unknown[]) => void; error: (...args: unknown[]) => void },
  ) {
    this.redis = redis;
    this.logger = logger;
  }

  /**
   * Start the WebSocket connection.
   */
  connect(): void {
    if (this.isShuttingDown) return;

    this.ws = new WebSocket(POLYMARKET_WS_URL);

    this.ws.on('open', () => {
      this.logger.info('Connected to Polymarket WebSocket');
      this.reconnectAttempts = 0;

      // Re-subscribe to all tracked tokens
      if (this.subscribedTokenIds.size > 0) {
        this.sendSubscribe([...this.subscribedTokenIds]);
      }

      // Start ping
      this.pingInterval = setInterval(() => {
        if (this.ws?.readyState === WebSocket.OPEN) {
          this.ws.ping();
        }
      }, PING_INTERVAL);
    });

    this.ws.on('message', (data) => {
      try {
        const updates = JSON.parse(data.toString());

        // Handle array of updates or single update
        const items = Array.isArray(updates) ? updates : [updates];

        for (const update of items) {
          if (update.asset_id && update.price) {
            // Publish to Redis channel
            const payload = JSON.stringify({
              type: 'price',
              tokenId: update.asset_id,
              price: update.price,
              timestamp: update.timestamp || Date.now(),
            });

            this.redis.publish(`prices:${update.asset_id}`, payload);

            // Also cache latest price
            this.redis.set(
              `price:latest:${update.asset_id}`,
              payload,
              'EX',
              60, // 60s TTL
            );
          }
        }
      } catch (err) {
        this.logger.error('Failed to parse Polymarket WS message:', err);
      }
    });

    this.ws.on('close', () => {
      this.logger.info('Polymarket WebSocket closed');
      this.cleanup();

      if (!this.isShuttingDown) {
        this.scheduleReconnect();
      }
    });

    this.ws.on('error', (err) => {
      this.logger.error('Polymarket WebSocket error:', err);
    });
  }

  /**
   * Subscribe to price updates for given token IDs.
   */
  subscribe(tokenIds: string[]): void {
    for (const id of tokenIds) {
      this.subscribedTokenIds.add(id);
    }

    if (this.ws?.readyState === WebSocket.OPEN) {
      this.sendSubscribe(tokenIds);
    }
  }

  /**
   * Unsubscribe from token IDs.
   */
  unsubscribe(tokenIds: string[]): void {
    for (const id of tokenIds) {
      this.subscribedTokenIds.delete(id);
    }
    // Note: Polymarket WS doesn't have explicit unsubscribe,
    // we just stop tracking and ignore updates for these tokens
  }

  /**
   * Update subscriptions for market rotation (new 5-min market).
   */
  rotateSubscriptions(oldTokenIds: string[], newTokenIds: string[]): void {
    this.unsubscribe(oldTokenIds);
    this.subscribe(newTokenIds);
  }

  /**
   * Gracefully shut down the connection.
   */
  async shutdown(): Promise<void> {
    this.isShuttingDown = true;
    this.cleanup();
    this.ws?.close();
  }

  private sendSubscribe(tokenIds: string[]): void {
    this.ws?.send(
      JSON.stringify({
        type: 'subscribe',
        channel: 'market',
        assets_id: tokenIds,
      }),
    );
  }

  private cleanup(): void {
    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }

  private scheduleReconnect(): void {
    const delay = Math.min(
      RECONNECT_BASE_DELAY * Math.pow(2, this.reconnectAttempts),
      MAX_RECONNECT_DELAY,
    );
    this.reconnectAttempts++;
    this.logger.info(`Reconnecting to Polymarket WS in ${delay}ms (attempt ${this.reconnectAttempts})`);
    setTimeout(() => this.connect(), delay);
  }
}
