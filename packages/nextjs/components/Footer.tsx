"use client";

import { SwitchTheme } from "~~/components/SwitchTheme";

/**
 * Site footer
 */
export const Footer = () => {
  return (
    <footer className="py-8 px-4 border-t border-base-300 mt-auto">
      <div className="max-w-7xl mx-auto flex flex-col items-center gap-3 text-sm text-base-content/60">
        <p className="m-0 text-center">CLAWD Limit Order · Permissionless onchain limit orders on Base</p>
        <p className="m-0 text-center">
          Contract:{" "}
          <a
            href="https://basescan.org/address/0xf32db9C489273713D037312E7b689e885Aa50F58"
            target="_blank"
            rel="noreferrer"
            className="underline"
          >
            0xf32db9...50F58
          </a>
        </p>
        <SwitchTheme />
      </div>
    </footer>
  );
};
