"use client";

import { useState } from "react";
import { formatClawd, formatUsd, humanPriceToLimitPrice } from "~~/app/_components/orderMath";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

export const BuybackPanel = () => {
  const [priceInput, setPriceInput] = useState("");
  const [triggering, setTriggering] = useState(false);

  const { data: reserve, refetch } = useScaffoldReadContract({
    contractName: "CLAWDLimitOrder",
    functionName: "buybackReserveUSDC",
  });

  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "CLAWDLimitOrder" });

  const reserveAmount = reserve ?? 0n;

  // limitPrice units = USDC(6dp) per 1e18 CLAWD. Expected CLAWD out (18dp) for the
  // full reserve = reserve(6dp) * 1e24 / price. Apply 1% slippage.
  let limitPrice = 0n;
  let priceError = "";
  try {
    if (priceInput) limitPrice = humanPriceToLimitPrice(priceInput);
  } catch {
    priceError = "Invalid price";
  }

  const expectedClawd = limitPrice > 0n ? (reserveAmount * 10n ** 24n) / limitPrice : 0n;
  const minClawdOut = (expectedClawd * 99n) / 100n; // 1% slippage tolerance

  const canTrigger = reserveAmount > 0n && limitPrice > 0n && !priceError && !triggering;

  const handleBuyback = async () => {
    if (!canTrigger) return;
    try {
      setTriggering(true);
      await writeContractAsync({ functionName: "executeBuyback", args: [minClawdOut] });
      notification.success("Buyback executed!");
      await refetch();
    } catch (e) {
      console.error(e);
    } finally {
      setTriggering(false);
    }
  };

  return (
    <div className="bg-base-100 rounded-box shadow-md p-6 w-full">
      <h2 className="text-xl font-bold mb-4">Buyback</h2>
      <div className="flex flex-col gap-4">
        <div className="stat bg-base-200 rounded-box p-4">
          <div className="stat-title">Buyback Reserve</div>
          <div className="stat-value text-2xl">{formatUsd(reserveAmount)}</div>
        </div>

        <label className="form-control w-full">
          <div className="label">
            <span className="label-text">Current CLAWD price ($ per CLAWD)</span>
          </div>
          <input
            type="number"
            min="0"
            step="any"
            placeholder="0.05"
            className="input input-bordered w-full bg-base-200"
            value={priceInput}
            onChange={e => setPriceInput(e.target.value)}
          />
          <div className="label">
            <span className="label-text-alt text-base-content/60">
              Used to compute minClawdOut with 1% slippage tolerance.
            </span>
          </div>
        </label>

        {limitPrice > 0n && reserveAmount > 0n && (
          <div className="text-sm bg-base-200 rounded-box p-3 flex justify-between">
            <span className="text-base-content/60">Min CLAWD out (1% slippage)</span>
            <span>{formatClawd(minClawdOut)}</span>
          </div>
        )}

        <button className="btn btn-secondary w-full" onClick={handleBuyback} disabled={!canTrigger}>
          {triggering && <span className="loading loading-spinner loading-sm" />}
          Trigger Buyback
        </button>
        {reserveAmount === 0n && (
          <p className="text-xs text-base-content/60 text-center">No reserve to buy back yet.</p>
        )}
      </div>
    </div>
  );
};
