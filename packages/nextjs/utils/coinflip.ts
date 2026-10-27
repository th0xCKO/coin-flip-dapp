import { formatUnits } from "viem";

// Mirrors CoinFlip.sol enums and constants.
export const BUY_IN = 10_000_000n; // 10 USDC, 6 decimals
export const POT = 2n * BUY_IN;
export const FLIP_TIMEOUT_SECONDS = 60n * 60n;

export const SIDES = ["Heads", "Tails"] as const;
export type SideLabel = (typeof SIDES)[number];

export enum GameStatus {
  None,
  Open,
  Flipping,
  Settled,
  Cancelled,
  Refunded,
}

export const sideLabel = (side: number) => SIDES[side] ?? "?";
export const oppositeSide = (side: number) => (side === 0 ? 1 : 0);
export const formatUsdc = (amount: bigint) => formatUnits(amount, 6);

export const USDC_SWAP_HINT = "Swap a little Sepolia ETH for USDC on Uniswap, then come back.";
