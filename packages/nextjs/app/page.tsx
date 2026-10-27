"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { NextPage } from "next";
import { parseEventLogs } from "viem";
import { useAccount } from "wagmi";
import { UsdcBalance } from "~~/components/coinflip/UsdcBalance";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";
import { useDeployedContractInfo, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { useUsdc } from "~~/hooks/useUsdc";
import { SIDES } from "~~/utils/coinflip";

const Home: NextPage = () => {
  const router = useRouter();
  const { isConnected } = useAccount();
  const { data: coinFlip } = useDeployedContractInfo({ contractName: "CoinFlip" });
  const { writeContractAsync: writeCoinFlip } = useScaffoldWriteContract({ contractName: "CoinFlip" });
  const { hasBuyIn, ensureBuyInAllowance, refetch: refetchUsdc } = useUsdc();

  const [side, setSide] = useState(0);
  const [creating, setCreating] = useState(false);
  const [joinId, setJoinId] = useState("");

  const createGame = async () => {
    if (!coinFlip) return;
    setCreating(true);
    try {
      if (!(await ensureBuyInAllowance())) return;
      await writeCoinFlip(
        { functionName: "createGame", args: [side] },
        {
          onBlockConfirmation: receipt => {
            const [created] = parseEventLogs({ abi: coinFlip.abi, eventName: "GameCreated", logs: receipt.logs });
            if (created) router.push(`/game/${created.args.gameId}`);
          },
        },
      );
    } catch {
      // useTransactor already showed the error
    } finally {
      setCreating(false);
      refetchUsdc();
    }
  };

  const joinIdValid = /^\d+$/.test(joinId) && BigInt(joinId) > 0n;

  return (
    <div className="flex flex-col items-center grow pt-10 px-4 gap-8">
      <div className="text-center">
        <h1 className="text-4xl font-bold mb-2">Coin Flip</h1>
        <p className="m-0 opacity-80">Two players, 10 USDC each. Chainlink VRF flips the coin; the winner takes 20.</p>
      </div>

      {!isConnected ? (
        <div className="card bg-base-100 shadow-xl p-6 items-center gap-3">
          <p className="m-0">Connect MetaMask or WalletConnect to play.</p>
          <RainbowKitCustomConnectButton />
        </div>
      ) : (
        <>
          <UsdcBalance />

          <div className="grid gap-6 md:grid-cols-2 w-full max-w-3xl">
            <div className="card bg-base-100 shadow-xl">
              <div className="card-body">
                <h2 className="card-title">Start a game</h2>
                <p className="m-0 text-sm opacity-80">
                  Pick your side. Your opponent gets the other one. You&apos;ll confirm two transactions: approve 10
                  USDC, then create.
                </p>
                <div className="join w-full my-2">
                  {SIDES.map((label, i) => (
                    <button
                      key={label}
                      className={`btn join-item flex-1 ${side === i ? "btn-primary" : "btn-outline"}`}
                      onClick={() => setSide(i)}
                    >
                      {label}
                    </button>
                  ))}
                </div>
                <button className="btn btn-primary" disabled={creating || !hasBuyIn} onClick={createGame}>
                  {creating ? <span className="loading loading-spinner loading-sm" /> : null}
                  Bet 10 USDC on {SIDES[side]}
                </button>
              </div>
            </div>

            <div className="card bg-base-100 shadow-xl">
              <div className="card-body">
                <h2 className="card-title">Join a game</h2>
                <p className="m-0 text-sm opacity-80">Enter the game number your opponent shared with you.</p>
                <form
                  className="flex flex-col gap-3 my-2"
                  onSubmit={e => {
                    e.preventDefault();
                    if (joinIdValid) router.push(`/game/${BigInt(joinId)}`);
                  }}
                >
                  <input
                    className="input input-bordered w-full"
                    inputMode="numeric"
                    placeholder="Game # (e.g. 7)"
                    value={joinId}
                    onChange={e => setJoinId(e.target.value.trim())}
                  />
                  <button className="btn btn-secondary" type="submit" disabled={!joinIdValid}>
                    Open game
                  </button>
                </form>
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  );
};

export default Home;
