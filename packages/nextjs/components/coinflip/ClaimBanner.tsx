"use client";

import { useAccount } from "wagmi";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { formatUsdc } from "~~/utils/coinflip";

/** Shows USDC whose automatic payout or refund failed and is held for the connected wallet in `claimable`. */
export const ClaimBanner = () => {
  const { address } = useAccount();
  const { data: claimable, refetch } = useScaffoldReadContract({
    contractName: "CoinFlip",
    functionName: "claimable",
    args: [address],
  });
  const { writeContractAsync, isMining } = useScaffoldWriteContract({ contractName: "CoinFlip" });
  if (!address || claimable === undefined || claimable === 0n) return null;

  const claim = async () => {
    try {
      await writeContractAsync({ functionName: "claim" });
    } catch {
      // useTransactor already showed the error
    } finally {
      refetch();
    }
  };

  return (
    <div className="alert alert-info flex justify-between w-full max-w-xl">
      <span>You have {formatUsdc(claimable)} USDC waiting to be claimed.</span>
      <button className="btn btn-sm" disabled={isMining} onClick={claim}>
        Claim
      </button>
    </div>
  );
};
