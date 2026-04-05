export interface ActiveMarket {
  slug: string;
  conditionId: string;
  upTokenId: string;
  downTokenId: string;
  endDate: string;
  question: string;
  negRisk?: boolean;
}

export interface MarketPrice {
  tokenId: string;
  price: string;
  timestamp: number;
}

export interface GammaEvent {
  id: string;
  slug: string;
  title: string;
  description: string;
  closed: boolean;
  endDate: string;
  negRisk?: boolean;
  markets: GammaMarket[];
}

export interface GammaMarket {
  id: string;
  conditionId: string;
  question: string;
  clobTokenIds: string[] | string; // Gamma API returns JSON string, not native array
  outcomePrices: string;
  volume: string;
  negRisk?: boolean;
}

export interface ClobOrderResponse {
  orderID: string;
  status: string;
  transactionsHashes?: string[];
}

export interface PositionData {
  size: number;
  avgPrice: number;
  initialValue: number;
  currentValue: number;
  cashPnl: number;
  percentPnl: number;
}

export interface PriceUpdate {
  type: 'price';
  tokenId: string;
  price: string;
  timestamp: number;
}
