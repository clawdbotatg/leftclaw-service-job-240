"use client";

import { BuybackPanel } from "./_components/BuybackPanel";
import { KeeperOrdersTable } from "./_components/KeeperOrdersTable";
import type { NextPage } from "next";
import { ClientOnly } from "~~/app/_components/ClientOnly";
import { useScaffoldEventHistory } from "~~/hooks/scaffold-eth";

const OpenOrdersSection = () => {
  const { data: placedEvents, isLoading } = useScaffoldEventHistory({
    contractName: "CLAWDLimitOrder",
    eventName: "OrderPlaced",
    fromBlock: 47002015n,
    watch: true,
  });

  const allOrderIds = (placedEvents ?? [])
    .map(e => e.args.orderId as bigint | undefined)
    .filter((id): id is bigint => id !== undefined);

  if (isLoading) {
    return (
      <div className="flex justify-center py-8">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }
  if (allOrderIds.length === 0) {
    return <p className="text-base-content/60 text-center py-8">No orders found.</p>;
  }
  return <KeeperOrdersTable orderIds={allOrderIds} />;
};

const Keeper: NextPage = () => {
  const spinner = (
    <div className="flex justify-center py-8">
      <span className="loading loading-spinner loading-lg" />
    </div>
  );

  return (
    <div className="flex flex-col grow pt-12 px-5 w-full max-w-5xl mx-auto">
      <div className="mb-8">
        <h1 className="text-3xl font-bold mb-2">Keeper Dashboard</h1>
        <p className="text-base-content/70">
          Execute open limit orders to earn 0.1% of order size, and trigger permissionless buybacks.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2 bg-base-100 rounded-box shadow-md p-6">
          <h2 className="text-xl font-bold mb-4">Open Orders</h2>
          <ClientOnly fallback={spinner}>
            <OpenOrdersSection />
          </ClientOnly>
        </div>

        <div className="lg:col-span-1">
          <ClientOnly fallback={spinner}>
            <BuybackPanel />
          </ClientOnly>
        </div>
      </div>
    </div>
  );
};

export default Keeper;
