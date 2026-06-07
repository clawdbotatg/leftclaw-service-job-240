import { formatUnits, parseUnits } from "viem";

// Contract constants (bps)
export const SWAP_BPS = 9970n;
export const BPS_DENOMINATOR = 10000n;
export const KEEPER_FEE_BPS = 10n;
export const TREASURY_FEE_BPS = 10n;
export const BUYBACK_FEE_BPS = 10n;
export const MIN_ORDER_SIZE_USDC = 100_000_000n; // $100 (6 decimals)

export const USDC_DECIMALS = 6;
export const CLAWD_DECIMALS = 18;

/**
 * limitPrice is stored as "USDC (6 decimals) you'd receive for 1e18 CLAWD".
 * Human-readable price in $/CLAWD = Number(formatUnits(limitPrice, 6)).
 */
export const limitPriceToHuman = (limitPriceRaw: bigint): number => Number(formatUnits(limitPriceRaw, USDC_DECIMALS));

/** Convert a human "$ per CLAWD" string (e.g. "0.05") into contract limitPrice units. */
export const humanPriceToLimitPrice = (humanPrice: string): bigint => parseUnits(humanPrice, USDC_DECIMALS);

/** Format a USDC base-unit amount as a "$X.XX" string. */
export const formatUsd = (usdcRaw: bigint, fractionDigits = 2): string => {
  const value = Number(formatUnits(usdcRaw, USDC_DECIMALS));
  return `$${value.toLocaleString(undefined, { minimumFractionDigits: fractionDigits, maximumFractionDigits: fractionDigits })}`;
};

/** Format a CLAWD base-unit amount with thousands separators. */
export const formatClawd = (clawdRaw: bigint, fractionDigits = 2): string => {
  const value = Number(formatUnits(clawdRaw, CLAWD_DECIMALS));
  return value.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: fractionDigits });
};

/** The USDC amount that is actually swapped (after the 0.3% combined fee carve-out). */
export const swapAmount = (usdcAmount: bigint): bigint => (usdcAmount * SWAP_BPS) / BPS_DENOMINATOR;

/** Keeper fee earned for executing an order: 0.1% of the full USDC amount. */
export const keeperFee = (usdcAmount: bigint): bigint => (usdcAmount * KEEPER_FEE_BPS) / BPS_DENOMINATOR;

export const treasuryFee = (usdcAmount: bigint): bigint => (usdcAmount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;

export const buybackFee = (usdcAmount: bigint): bigint => (usdcAmount * BUYBACK_FEE_BPS) / BPS_DENOMINATOR;

/**
 * Expected CLAWD out (18 decimals) for a given USDC amount (6 decimals) at limitPrice.
 *
 * swapUSDC (6dp) is swapped; CLAWD price in USD = limitPrice / 1e6.
 * clawdOut (18dp) = swapUSDC * 1e18 / (limitPrice / 1e6) = swapUSDC * 1e24 / limitPrice.
 */
export const expectedClawdOut = (usdcAmount: bigint, limitPriceRaw: bigint): bigint => {
  if (limitPriceRaw === 0n) return 0n;
  return (swapAmount(usdcAmount) * 10n ** 24n) / limitPriceRaw;
};

/** minAmountOut with a slippage tolerance (in bps, e.g. 50 = 0.5%). */
export const minAmountOutWithSlippage = (usdcAmount: bigint, limitPriceRaw: bigint, slippageBps = 50n): bigint => {
  const expected = expectedClawdOut(usdcAmount, limitPriceRaw);
  return (expected * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
};
