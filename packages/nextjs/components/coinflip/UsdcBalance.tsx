"use client";

import { MintTestUsdcButton } from "./LocalDevActions";
import { useAccount } from "wagmi";
import { useUsdc } from "~~/hooks/useUsdc";
import { USDC_SWAP_HINT, formatUsdc } from "~~/utils/coinflip";

export const UsdcBalance = () => {
  const { isConnected } = useAccount();
  const { balance, hasBuyIn } = useUsdc();
  if (!isConnected || balance === undefined) return null;

  return (
    <div className="flex flex-col items-center gap-2 text-sm">
      <p className="m-0">
        Your USDC balance: <span className="font-bold">{formatUsdc(balance)}</span>
      </p>
      {!hasBuyIn && <p className="m-0 text-warning">You need 10 USDC to play. {USDC_SWAP_HINT}</p>}
      <MintTestUsdcButton />
    </div>
  );
};
