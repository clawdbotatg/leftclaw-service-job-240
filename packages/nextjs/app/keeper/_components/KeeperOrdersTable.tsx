"use client";

import { useState } from "react";
import { Address } from "@scaffold-ui/components";
import { formatUsd, keeperFee, limitPriceToHuman } from "~~/app/_components/orderMath";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

type OrderTuple = readonly [string, bigint, bigint, bigint, boolean, boolean];

const KeeperOrderRow = ({ orderId }: { orderId: bigint }) => {
  const [executing, setExecuting] = useState(false);
  const { data: order, refetch } = useScaffoldReadContract({
    contractName: "CLAWDLimitOrder",
    functionName: "getOrder",
    args: [orderId],
  });
  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "CLAWDLimitOrder" });

  if (!order) return null;

  const [owner, usdcAmount, limitPrice, , executed, cancelled] = order as unknown as OrderTuple;
  // Only render still-open orders.
  if (executed || cancelled) return null;

  const handleExecute = async () => {
    if (executing) return;
    try {
      setExecuting(true);
      await writeContractAsync({ functionName: "executeOrder", args: [orderId] });
      notification.success(`Order #${orderId.toString()} executed`);
      await refetch();
    } catch (e) {
      const _msg = e instanceof Error ? e.message : String(e);
      if (!_msg.includes("rejected") && !_msg.includes("denied"))
        notification.error("Transaction failed. Please try again.");
    } finally {
      setExecuting(false);
    }
  };

  return (
    <tr>
      <td>{orderId.toString()}</td>
      <td>
        <Address address={owner} size="sm" />
      </td>
      <td>{formatUsd(usdcAmount)}</td>
      <td>${limitPriceToHuman(limitPrice).toLocaleString(undefined, { maximumFractionDigits: 6 })}</td>
      <td className="text-success">{formatUsd(keeperFee(usdcAmount))}</td>
      <td>
        <button className="btn btn-xs btn-primary" onClick={handleExecute} disabled={executing}>
          {executing && <span className="loading loading-spinner loading-xs" />}
          Execute
        </button>
      </td>
    </tr>
  );
};

export const KeeperOrdersTable = ({ orderIds }: { orderIds: bigint[] }) => {
  const sorted = [...orderIds].sort((a, b) => (a > b ? -1 : 1));
  return (
    <div className="overflow-x-auto">
      <table className="table">
        <thead>
          <tr>
            <th>ID</th>
            <th>Owner</th>
            <th>USDC</th>
            <th>Limit Price ($/CLAWD)</th>
            <th>Keeper Fee</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {sorted.map(id => (
            <KeeperOrderRow key={id.toString()} orderId={id} />
          ))}
        </tbody>
      </table>
    </div>
  );
};
