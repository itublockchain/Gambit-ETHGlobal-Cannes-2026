import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { WebSocket } from 'ws';

interface ClientSubscription {
  ws: WebSocket;
  tokenIds: Set<string>;
  userId?: string;
}

const clients = new Map<WebSocket, ClientSubscription>();

export default async function pricesWs(fastify: FastifyInstance) {
  // Subscribe to all Redis price channels
  fastify.redisSub.psubscribe('prices:*', (err) => {
    if (err) fastify.log.error({ err }, 'Redis psubscribe error');
  });

  // Forward Redis messages to appropriate WebSocket clients
  fastify.redisSub.on('pmessage', (_pattern, channel, message) => {
    const tokenId = channel.replace('prices:', '');

    for (const [, client] of clients) {
      if (client.tokenIds.has(tokenId) && client.ws.readyState === 1) {
        client.ws.send(message);
      }
    }
  });

  /**
   * WS /ws/prices
   * Real-time price stream for iOS clients.
   */
  fastify.get('/prices', { websocket: true }, (socket: WebSocket, request: FastifyRequest) => {
    const client: ClientSubscription = {
      ws: socket,
      tokenIds: new Set(),
    };
    clients.set(socket, client);

    fastify.log.info(`WebSocket client connected (total: ${clients.size})`);

    socket.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString()) as {
          action: 'subscribe' | 'unsubscribe';
          tokenIds: string[];
        };

        if (msg.action === 'subscribe' && Array.isArray(msg.tokenIds)) {
          for (const id of msg.tokenIds) {
            client.tokenIds.add(id);
          }

          // Send latest cached prices immediately
          for (const tokenId of msg.tokenIds) {
            fastify.redis.get(`price:latest:${tokenId}`).then((cached) => {
              if (cached && socket.readyState === 1) {
                socket.send(cached);
              }
            });
          }
        }

        if (msg.action === 'unsubscribe' && Array.isArray(msg.tokenIds)) {
          for (const id of msg.tokenIds) {
            client.tokenIds.delete(id);
          }
        }
      } catch {
        // Ignore malformed messages
      }
    });

    socket.on('close', () => {
      clients.delete(socket);
      fastify.log.info(`WebSocket client disconnected (total: ${clients.size})`);
    });

    socket.on('error', (err) => {
      fastify.log.error({ err }, 'WebSocket client error');
      clients.delete(socket);
    });
  });
}
