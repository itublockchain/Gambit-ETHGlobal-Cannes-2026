import { POLYMARKET_GAMMA_URL, POLYMARKET_CLOB_URL, type SupportedAsset } from '../../config.js';
import type { ActiveMarket, GammaEvent } from '../../types/polymarket.js';

/**
 * Get CLOB server time. Falls back to local time if CLOB is unreachable.
 */
async function getServerTime(): Promise<number> {
  try {
    const res = await fetch(`${POLYMARKET_CLOB_URL}/time`);
    if (res.ok) return parseInt(await res.text());
  } catch {}
  return Math.floor(Date.now() / 1000);
}

/**
 * Parse a Gamma event into our ActiveMarket model.
 */
function parseMarket(event: GammaEvent, slug: string): ActiveMarket | null {
  try {
    const market = event.markets?.[0];
    if (!market) return null;

    const tokenIds: string[] =
      typeof market.clobTokenIds === 'string'
        ? JSON.parse(market.clobTokenIds)
        : market.clobTokenIds;

    if (!tokenIds || tokenIds.length < 2) return null;

    return {
      slug,
      conditionId: market.conditionId,
      upTokenId: tokenIds[0],
      downTokenId: tokenIds[1],
      endDate: event.endDate,
      question: market.question || event.title,
      negRisk: market.negRisk ?? false,
    };
  } catch {
    return null;
  }
}

/**
 * Find the currently LIVE 5-minute market for an asset.
 * Uses CLOB server time → slug calculation → Gamma API → live check.
 */
export async function findActiveMarket(asset: SupportedAsset): Promise<ActiveMarket | null> {
  const serverTime = await getServerTime();
  const nowMs = serverTime * 1000;
  const rounded = Math.floor(serverTime / 300) * 300;

  // Try current 5-min window and immediate neighbors
  for (const offset of [0, -300, 300, -600, 600]) {
    const ts = rounded + offset;
    const slug = `${asset}-updown-5m-${ts}`;

    try {
      const res = await fetch(`${POLYMARKET_GAMMA_URL}/events/slug/${slug}`, {
        signal: AbortSignal.timeout(5000),
      });
      if (!res.ok) continue;

      const event = (await res.json()) as GammaEvent;
      if (!event?.markets?.length) continue;

      const endMs = new Date(event.endDate).getTime();
      const startMs = endMs - 5 * 60 * 1000;

      // Live: current time is inside the 5-min window
      if (nowMs >= startMs && nowMs < endMs) {
        const market = parseMarket(event, slug);
        if (market) return market;
      }
    } catch {
      continue;
    }
  }

  return null;
}

/**
 * Get current price for a token from the CLOB.
 */
export async function getTokenPrice(
  tokenId: string,
  side: 'BUY' | 'SELL' = 'BUY',
): Promise<string> {
  const res = await fetch(`${POLYMARKET_CLOB_URL}/price?token_id=${tokenId}&side=${side}`, {
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`Price fetch failed: ${res.status}`);
  const data = (await res.json()) as { price: string };
  return data.price;
}

export async function getClobServerTime(): Promise<number> {
  return getServerTime();
}
