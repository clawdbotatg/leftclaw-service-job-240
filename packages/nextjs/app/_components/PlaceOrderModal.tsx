"use client";

import { useEffect, useState } from "react";
import {
  MIN_ORDER_SIZE_USDC,
  buybackFee,
  expectedClawdOut,
  formatClawd,
  formatUsd,
  humanPriceToLimitPrice,
  keeperFee,
  minAmountOutWithSlippage,
  swapAmount,
  treasuryFee,
} from "./orderMath";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { maxUint256, parseUnits } from "viem";
import { base } from "viem/chains";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

const CONTRACT_ADDRESS = "0xf32db9C489273713D037312E7b689e885Aa50F58";

type Props = {
  onClose: () => void;
};

export const PlaceOrderModal = ({ onClose }: Props) => {
  const { address: connectedAddress, isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const { openConnectModal } = useConnectModal();

  const [usdcInput, setUsdcInput] = useState("");
  const [priceInput, setPriceInput] = useState("");

  // Two-state protection for approval: submitting + post-confirmation cooldown.
  const [approving, setApproving] = useState(false);
  const [approveCooldown, setApproveCooldown] = useState(false);
  const [placing, setPlacing] = useState(false);

  const onBase = chainId === base.id;

  // Parse inputs into contract units (guarded so bad input doesn't throw).
  let usdcAmount = 0n;
  let limitPrice = 0n;
  let parseError = "";
  try {
    if (usdcInput) usdcAmount = parseUnits(usdcInput, 6);
  } catch {
    parseError = "Invalid USDC amount";
  }
  try {
    if (priceInput) limitPrice = humanPriceToLimitPrice(priceInput);
  } catch {
    parseError = "Invalid limit price";
  }

  const minAmountOut = usdcAmount > 0n && limitPrice > 0n ? minAmountOutWithSlippage(usdcAmount, limitPrice) : 0n;
  const expectedOut = usdcAmount > 0n && limitPrice > 0n ? expectedClawdOut(usdcAmount, limitPrice) : 0n;

  const belowMin = usdcAmount > 0n && usdcAmount < MIN_ORDER_SIZE_USDC;
  const inputsValid = usdcAmount > 0n && limitPrice > 0n && !belowMin && !parseError;

  const { data: usdcBalance } = useScaffoldReadContract({
    contractName: "USDC",
    functionName: "balanceOf",
    args: [connectedAddress],
  });

  const { data: allowance, refetch: refetchAllowance } = useScaffoldReadContract({
    contractName: "USDC",
    functionName: "allowance",
    args: [connectedAddress, CONTRACT_ADDRESS],
  });

  const { writeContractAsync: writeUsdc } = useScaffoldWriteContract({ contractName: "USDC" });
  const { writeContractAsync: writeOrder } = useScaffoldWriteContract({ contractName: "CLAWDLimitOrder" });

  const needsApproval = inputsValid && (allowance === undefined || allowance < usdcAmount);
  const insufficientBalance = usdcBalance !== undefined && usdcAmount > usdcBalance;

  // Release the cooldown once allowance has caught up.
  useEffect(() => {
    if (approveCooldown && allowance !== undefined && usdcAmount > 0n && allowance >= usdcAmount) {
      setApproveCooldown(false);
    }
  }, [approveCooldown, allowance, usdcAmount]);

  const handleApprove = async () => {
    if (approving || approveCooldown) return;
    try {
      setApproving(true);
      await writeUsdc({
        functionName: "approve",
        args: [CONTRACT_ADDRESS, maxUint256],
      });
      setApproveCooldown(true);
      await refetchAllowance();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (!msg.includes("rejected") && !msg.includes("denied")) {
        notification.error("Approval failed. Please try again.");
      }
    } finally {
      setApproving(false);
    }
  };

  const handlePlace = async () => {
    if (placing || !inputsValid) return;
    try {
      setPlacing(true);
      await writeOrder({
        functionName: "placeOrder",
        args: [usdcAmount, limitPrice, minAmountOut],
      });
      notification.success("Order placed!");
      onClose();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (!msg.includes("rejected") && !msg.includes("denied")) {
        notification.error("Failed to place order. Please try again.");
      }
    } finally {
      setPlacing(false);
    }
  };

  const renderActionButton = () => {
    if (!isConnected) {
      return (
        <button className="btn btn-primary w-full" onClick={openConnectModal}>
          Connect Wallet
        </button>
      );
    }
    if (!onBase) {
      return (
        <button
          className="btn btn-warning w-full"
          onClick={() => switchChain({ chainId: base.id })}
          disabled={isSwitching}
        >
          {isSwitching && <span className="loading loading-spinner loading-sm" />}
          Switch to Base
        </button>
      );
    }
    if (needsApproval) {
      return (
        <button
          className="btn btn-secondary w-full"
          onClick={handleApprove}
          disabled={approving || approveCooldown || !inputsValid || insufficientBalance}
        >
          {(approving || approveCooldown) && <span className="loading loading-spinner loading-sm" />}
          {approving ? "Approving..." : approveCooldown ? "Confirming..." : "Approve USDC"}
        </button>
      );
    }
    return (
      <button
        className="btn btn-primary w-full"
        onClick={handlePlace}
        disabled={!inputsValid || placing || insufficientBalance}
      >
        {placing && <span className="loading loading-spinner loading-sm" />}
        Place Order
      </button>
    );
  };

  return (
    <div className="modal modal-open">
      <div className="modal-box bg-base-100 max-w-lg">
        <div className="flex justify-between items-center mb-4">
          <h3 className="font-bold text-lg">Place Limit Order</h3>
          <button className="btn btn-sm btn-circle btn-ghost" onClick={onClose}>
            ✕
          </button>
        </div>

        <div className="flex flex-col gap-4">
          <label className="form-control w-full">
            <div className="label">
              <span className="label-text">USDC amount</span>
              {usdcBalance !== undefined && (
                <span className="label-text-alt text-base-content/60">Balance: {formatUsd(usdcBalance)}</span>
              )}
            </div>
            <input
              type="number"
              min="0"
              step="any"
              placeholder="1000"
              className="input input-bordered w-full bg-base-200"
              value={usdcInput}
              onChange={e => setUsdcInput(e.target.value)}
            />
            {belowMin && <span className="text-error text-xs mt-1">Minimum order size is $100</span>}
            {insufficientBalance && <span className="text-error text-xs mt-1">Insufficient USDC balance</span>}
          </label>

          <label className="form-control w-full">
            <div className="label">
              <span className="label-text">Limit price ($ per CLAWD)</span>
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
          </label>

          {inputsValid && (
            <div className="bg-base-200 rounded-box p-4 text-sm flex flex-col gap-1">
              <div className="flex justify-between">
                <span className="text-base-content/60">Swapped (after 0.3% fees)</span>
                <span>{formatUsd(swapAmount(usdcAmount))}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-base-content/60">Keeper fee (0.1%)</span>
                <span>{formatUsd(keeperFee(usdcAmount))}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-base-content/60">Treasury fee (0.1%)</span>
                <span>{formatUsd(treasuryFee(usdcAmount))}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-base-content/60">Buyback fee (0.1%)</span>
                <span>{formatUsd(buybackFee(usdcAmount))}</span>
              </div>
              <div className="divider my-1" />
              <div className="flex justify-between">
                <span className="text-base-content/60">Expected CLAWD out</span>
                <span>{formatClawd(expectedOut)}</span>
              </div>
              <div className="flex justify-between font-semibold">
                <span>Min CLAWD out (0.5% slippage)</span>
                <span>{formatClawd(minAmountOut)}</span>
              </div>
            </div>
          )}

          {renderActionButton()}
        </div>
      </div>
      <div className="modal-backdrop" onClick={onClose} />
    </div>
  );
};
