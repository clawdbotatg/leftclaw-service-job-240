"use client";

import { useState } from "react";
import { formatClawd, formatUsd, limitPriceToHuman } from "./orderMath";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

type OrderTuple = readonly [string, bigint, bigint, bigint, boolean, boolean];

const statusOf = (executed: boolean, cancelled: boolean): { label: string; cls: string } => {
  if (cancelled) return { label: "Cancelled", cls: "badge-error" };
  if (executed) return { label: "Executed", cls: "badge-success" };
  return { label: "Open", cls: "badge-info" };
};

const OrderRow = ({ orderId }: { orderId: bigint }) => {
  const [cancelling, setCancelling] = useState(false);
  const { data: order, refetch } = useScaffoldReadContract({
    contractName: "CLAWDLimitOrder",
    functionName: "getOrder",
    args: [orderId],
  });
  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "CLAWDLimitOrder" });

  if (!order) {
    return (
      <tr>
        <td colSpan={6}>
          <span className="loading loading-spinner loading-xs" />
        </td>
      </tr>
    );
  }

  const [, usdcAmount, limitPrice, minAmountOut, executed, cancelled] = order as unknown as OrderTuple;
  const status = statusOf(executed, cancelled);
  const isOpen = !executed && !cancelled;

  const handleCancel = async () => {
    if (cancelling) return;
    try {
      setCancelling(true);
      await writeContractAsync({ functionName: "cancelOrder", args: [orderId] });
      notification.success("Order cancelled");
      await refetch();
    } catch (e) {
      const _msg = e instanceof Error ? e.message : String(e);
      if (!_msg.includes("rejected") && !_msg.includes("denied"))
        notification.error("Transaction failed. Please try again.");
    } finally {
      setCancelling(false);
    }
  };

  return (
    <tr>
      <td>{orderId.toString()}</td>
      <td>{formatUsd(usdcAmount)}</td>
      <td>${limitPriceToHuman(limitPrice).toLocaleString(undefined, { maximumFractionDigits: 6 })}</td>
      <td>{formatClawd(minAmountOut)}</td>
      <td>
        <span className={`badge ${status.cls}`}>{status.label}</span>
      </td>
      <td>
        {isOpen && (
          <button className="btn btn-xs btn-error btn-outline" onClick={handleCancel} disabled={cancelling}>
            {cancelling && <span className="loading loading-spinner loading-xs" />}
            Cancel
          </button>
        )}
      </td>
    </tr>
  );
};

export const MyOrdersTable = ({ orderIds }: { orderIds: bigint[] }) => {
  const sorted = [...orderIds].sort((a, b) => (a > b ? -1 : 1));
  return (
    <div className="overflow-x-auto">
      <table className="table">
        <thead>
          <tr>
            <th>ID</th>
            <th>USDC</th>
            <th>Limit Price ($/CLAWD)</th>
            <th>Min CLAWD Out</th>
            <th>Status</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {sorted.map(id => (
            <OrderRow key={id.toString()} orderId={id} />
          ))}
        </tbody>
      </table>
    </div>
  );
};
