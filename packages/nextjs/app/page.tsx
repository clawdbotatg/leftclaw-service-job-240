"use client";

import { useState } from "react";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { ClientOnly } from "~~/app/_components/ClientOnly";
import { MyOrdersTable } from "~~/app/_components/MyOrdersTable";
import { PlaceOrderModal } from "~~/app/_components/PlaceOrderModal";
import { useScaffoldEventHistory } from "~~/hooks/scaffold-eth";

const CONTRACT_ADDRESS = "0xf32db9C489273713D037312E7b689e885Aa50F58" as const;

const MyOrdersSection = () => {
  const { address: connectedAddress, isConnected } = useAccount();

  const { data: placedEvents, isLoading } = useScaffoldEventHistory({
    contractName: "CLAWDLimitOrder",
    eventName: "OrderPlaced",
    fromBlock: 47002015n,
    watch: true,
  });

  const myOrderIds = (placedEvents ?? [])
    .filter(e => (e.args.owner as string | undefined)?.toLowerCase() === connectedAddress?.toLowerCase())
    .map(e => e.args.orderId as bigint)
    .filter((id): id is bigint => id !== undefined);

  if (!isConnected) {
    return <p className="text-base-content/60 text-center py-8">Connect your wallet to view and place orders.</p>;
  }
  if (isLoading) {
    return (
      <div className="flex justify-center py-8">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }
  if (myOrderIds.length === 0) {
    return <p className="text-base-content/60 text-center py-8">You have no orders yet.</p>;
  }
  return <MyOrdersTable orderIds={myOrderIds} />;
};

const Home: NextPage = () => {
  const [modalOpen, setModalOpen] = useState(false);

  return (
    <div className="flex flex-col grow">
      <div className="flex flex-col items-center grow pt-12 px-5 w-full max-w-5xl mx-auto">
        <div className="text-center mb-8">
          <h1 className="text-4xl font-bold mb-3">CLAWD Limit Order</h1>
          <p className="text-lg text-base-content/70 max-w-xl mx-auto">
            Permissionless onchain limit orders. Buy CLAWD when TWAP hits your price.
          </p>
        </div>

        <button className="btn btn-primary btn-lg mb-10" onClick={() => setModalOpen(true)}>
          Place Order
        </button>

        <div className="w-full bg-base-100 rounded-box shadow-md p-6">
          <h2 className="text-xl font-bold mb-4">My Orders</h2>
          <ClientOnly
            fallback={
              <div className="flex justify-center py-8">
                <span className="loading loading-spinner loading-lg" />
              </div>
            }
          >
            <MyOrdersSection />
          </ClientOnly>
        </div>

        <div className="mt-10 mb-6 flex flex-col items-center gap-2 text-sm text-base-content/60">
          <span>Contract</span>
          <ClientOnly fallback={<span className="font-mono">0xf32db9...50F58</span>}>
            <Address address={CONTRACT_ADDRESS} />
          </ClientOnly>
        </div>
      </div>

      {modalOpen && (
        <ClientOnly>
          <PlaceOrderModal onClose={() => setModalOpen(false)} />
        </ClientOnly>
      )}
    </div>
  );
};

export default Home;
