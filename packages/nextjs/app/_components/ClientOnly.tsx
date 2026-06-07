"use client";

import { useEffect, useState } from "react";

/**
 * Renders children only after the component has mounted on the client.
 *
 * The app's provider tree (WagmiProvider/RainbowKit) is itself gated on mount,
 * so any component calling wagmi hooks must also wait for mount or it will throw
 * `useConfig must be used within WagmiProvider` during the static export pass.
 */
export const ClientOnly = ({
  children,
  fallback = null,
}: {
  children: React.ReactNode;
  fallback?: React.ReactNode;
}) => {
  const [mounted, setMounted] = useState(false);
  useEffect(() => {
    setMounted(true);
  }, []);
  if (!mounted) return <>{fallback}</>;
  return <>{children}</>;
};
