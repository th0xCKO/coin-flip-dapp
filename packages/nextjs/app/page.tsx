"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { NextPage } from "next";
import { parseEventLogs } from "viem";
import { useAccount } from "wagmi";
import { ClaimBanner } from "~~/components/coinflip/ClaimBanner";
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
      <div className="text-center max-w-2xl">
        <h1 className="text-4xl font-bold mb-4">Coin Flip: Escrow Edition 🪙</h1>
        <p className="text-xl font-semibold m-0 mb-2">Welcome, Crypto &amp; iGaming team!</p>
        <p className="m-0 opacity-80">
          Tomer built this little game to show on-chain escrow in action: a simple smart contract holds the money and
          settles it by rules written in code, with no middleman.
        </p>
      </div>

      <ul className="card bg-base-100 shadow-xl p-6 m-0 w-full max-w-2xl flex flex-col gap-3 list-none">
        <li>
          <strong className="mr-1">🔒 Lock it:</strong>you and an opponent each put 10 USDC into the contract. Once
          it&apos;s in, nobody can withdraw it mid-game, not even Tomer.
        </li>
        <li>
          <strong className="mr-1">🎲 Flip it:</strong>Chainlink&apos;s verifiable randomness tosses the coin. No one
          can rig it, and no one can peek.
        </li>
        <li>
          <strong className="mr-1">💸 Settle it:</strong>the contract pays the full 20 USDC to the winner automatically.
          Settlement T+1 minute, no reconciliation, and chargebacks aren&apos;t a thing here.
        </li>
        <li>
          <strong className="mr-1">🛟 Safety net:</strong>if the flip never arrives, both players get their money back
          after an hour.
        </li>
        <li className="text-sm italic opacity-70 text-center pt-1">
          Testnet USDC only: the money&apos;s fake, the bragging rights are real.
        </li>
      </ul>

      {!isConnected ? (
        <div className="card bg-base-100 shadow-xl p-6 items-center gap-3">
          <p className="m-0">Connect MetaMask or WalletConnect to play.</p>
          <RainbowKitCustomConnectButton />
        </div>
      ) : (
        <>
          <UsdcBalance />
          <ClaimBanner />

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
