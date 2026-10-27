"use client";

import { useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { Address } from "@scaffold-ui/components";
import { useQuery } from "@tanstack/react-query";
import type { NextPage } from "next";
import { useAccount, useBlock, usePublicClient } from "wagmi";
import { ClaimBanner } from "~~/components/coinflip/ClaimBanner";
import { AnswerFlipButton } from "~~/components/coinflip/LocalDevActions";
import { UsdcBalance } from "~~/components/coinflip/UsdcBalance";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";
import {
  useCopyToClipboard,
  useDeployedContractInfo,
  useScaffoldReadContract,
  useScaffoldWriteContract,
  useTargetNetwork,
} from "~~/hooks/scaffold-eth";
import { useUsdc } from "~~/hooks/useUsdc";
import { FLIP_TIMEOUT_SECONDS, GameStatus, POT, formatUsdc, oppositeSide, sideLabel } from "~~/utils/coinflip";
import { getBlockExplorerTxLink } from "~~/utils/scaffold-eth";

const sameAddress = (a?: string, b?: string) => Boolean(a && b && a.toLowerCase() === b.toLowerCase());

const Coin = ({ face, spinning }: { face?: string; spinning?: boolean }) => (
  <div
    className={`w-32 h-32 rounded-full bg-warning text-warning-content flex items-center justify-center text-2xl font-bold shadow-xl border-4 border-warning-content/20 ${
      spinning ? "animate-spin" : ""
    }`}
    style={spinning ? { animationDuration: "1.2s" } : undefined}
  >
    {face ?? "?"}
  </div>
);

const GamePage: NextPage = () => {
  const params = useParams<{ id: string }>();
  const idValid = /^\d+$/.test(params.id);
  const gameId = idValid ? BigInt(params.id) : 0n;

  const { address: account, isConnected } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const publicClient = usePublicClient({ chainId: targetNetwork.id });
  // The refund timeout is enforced against block.timestamp, so compare against chain time, not the browser clock.
  const { data: latestBlock } = useBlock({ chainId: targetNetwork.id, watch: true });
  const { data: coinFlip } = useDeployedContractInfo({ contractName: "CoinFlip" });
  const { copyToClipboard, isCopiedToClipboard } = useCopyToClipboard();

  const { data: game, refetch: refetchGame } = useScaffoldReadContract({
    contractName: "CoinFlip",
    functionName: "getGame",
    args: [gameId],
  });
  const { writeContractAsync: writeCoinFlip, isMining } = useScaffoldWriteContract({ contractName: "CoinFlip" });
  const { hasBuyIn, ensureBuyInAllowance, refetch: refetchUsdc } = useUsdc();
  const [joining, setJoining] = useState(false);

  const status = game ? (game.status as GameStatus) : undefined;

  // The payout happens inside the Chainlink VRF callback tx; the contract records its block so one getLogs finds it.
  const { data: settledLog } = useQuery({
    queryKey: ["gameSettled", targetNetwork.id, coinFlip?.address, gameId.toString(), game?.settledBlock.toString()],
    enabled: Boolean(publicClient && coinFlip && game && status === GameStatus.Settled),
    staleTime: Infinity,
    queryFn: async () => {
      const logs = await publicClient!.getContractEvents({
        address: coinFlip!.address,
        abi: coinFlip!.abi,
        eventName: "GameSettled",
        args: { gameId },
        fromBlock: game!.settledBlock,
        toBlock: game!.settledBlock,
      });
      return logs[0] ?? null;
    },
  });

  const run = async (fn: () => Promise<unknown>) => {
    try {
      await fn();
    } catch {
      // useTransactor already showed the error
    } finally {
      refetchGame();
      refetchUsdc();
    }
  };

  const joinGame = async () => {
    setJoining(true);
    await run(async () => {
      if (await ensureBuyInAllowance()) await writeCoinFlip({ functionName: "joinGame", args: [gameId] });
    });
    setJoining(false);
  };

  if (!idValid) return <Message title="That isn't a game number." />;
  if (!game || !coinFlip) return <Message title="Loading game…" spinner />;
  if (status === GameStatus.None) return <Message title={`Game #${gameId} doesn't exist (yet).`} />;

  const isPlayer1 = sameAddress(account, game.player1);
  const isPlayer2 = sameAddress(account, game.player2);
  const player2SideLabel = sideLabel(oppositeSide(game.player1Side));
  const refundableAt = game.joinedAt + FLIP_TIMEOUT_SECONDS;
  const canRefund =
    status === GameStatus.Flipping && latestBlock !== undefined && latestBlock.timestamp >= refundableAt;
  const youWon = status === GameStatus.Settled && sameAddress(account, game.winner);
  const youLost = status === GameStatus.Settled && (isPlayer1 || isPlayer2) && !youWon;

  return (
    <div className="flex flex-col items-center grow pt-10 px-4 gap-6">
      <div className="text-center">
        <h1 className="text-3xl font-bold mb-1">Game #{gameId.toString()}</h1>
        <StatusBadge status={status!} />
      </div>

      <ClaimBanner />

      <Coin
        face={status === GameStatus.Settled ? sideLabel(game.result) : undefined}
        spinning={status === GameStatus.Flipping}
      />

      <div className="card bg-base-100 shadow-xl w-full max-w-xl">
        <div className="card-body gap-4">
          <div className="grid grid-cols-2 gap-4">
            <PlayerSlot
              title={`Player 1 · ${sideLabel(game.player1Side)}`}
              address={game.player1}
              you={isPlayer1}
              winner={status === GameStatus.Settled && sameAddress(game.winner, game.player1)}
            />
            <PlayerSlot
              title={`Player 2 · ${player2SideLabel}`}
              address={status === GameStatus.Open || status === GameStatus.Cancelled ? undefined : game.player2}
              you={isPlayer2}
              winner={status === GameStatus.Settled && sameAddress(game.winner, game.player2)}
            />
          </div>

          {status === GameStatus.Open && (
            <>
              {isPlayer1 ? (
                <div className="flex flex-col gap-2 items-center text-center">
                  <p className="m-0">
                    Waiting for an opponent. Tell them to join game <b>#{gameId.toString()}</b> or send this link:
                  </p>
                  <button className="btn btn-sm btn-outline" onClick={() => copyToClipboard(window.location.href)}>
                    {isCopiedToClipboard ? "Copied!" : "Copy game link"}
                  </button>
                  <button
                    className="btn btn-sm btn-ghost text-error"
                    disabled={isMining}
                    onClick={() => run(() => writeCoinFlip({ functionName: "cancelGame", args: [gameId] }))}
                  >
                    Cancel game and get my 10 USDC back
                  </button>
                </div>
              ) : !isConnected ? (
                <div className="flex flex-col items-center gap-2">
                  <p className="m-0">Connect your wallet to join as {player2SideLabel}.</p>
                  <RainbowKitCustomConnectButton />
                </div>
              ) : (
                <div className="flex flex-col items-center gap-2 text-center">
                  <p className="m-0">
                    You&apos;ll be <b>{player2SideLabel}</b>. Confirm two transactions: approve 10 USDC, then join.
                  </p>
                  <button className="btn btn-primary" disabled={joining || !hasBuyIn} onClick={joinGame}>
                    {joining ? <span className="loading loading-spinner loading-sm" /> : null}
                    Bet 10 USDC on {player2SideLabel}
                  </button>
                  <UsdcBalance />
                </div>
              )}
            </>
          )}

          {status === GameStatus.Flipping && (
            <div className="flex flex-col items-center gap-2 text-center">
              <p className="m-0">
                Both bets are in. Waiting for Chainlink VRF to deliver the random number (usually under a minute).
              </p>
              <AnswerFlipButton requestId={game.requestId} />
              {canRefund && (
                <button
                  className="btn btn-sm btn-warning"
                  disabled={isMining}
                  onClick={() => run(() => writeCoinFlip({ functionName: "refundGame", args: [gameId] }))}
                >
                  No answer after 1 hour: refund both players
                </button>
              )}
            </div>
          )}

          {status === GameStatus.Settled && (
            <div className="flex flex-col items-center gap-2 text-center">
              <p className="m-0 text-2xl font-bold">
                {sideLabel(game.result)}! {youWon ? "You won 🎉" : youLost ? "You lost" : ""}
              </p>
              <p className="m-0">
                <Address address={game.winner} chain={targetNetwork} /> won {formatUsdc(POT)} USDC.
              </p>
              {settledLog && settledLog.args.paid === false ? (
                <p className="m-0 text-warning">
                  The automatic transfer failed, so the pot is held for the winner to claim.
                </p>
              ) : null}
              {settledLog?.transactionHash && targetNetwork.blockExplorers ? (
                <a
                  className="link"
                  target="_blank"
                  rel="noreferrer"
                  href={getBlockExplorerTxLink(targetNetwork.id, settledLog.transactionHash)}
                >
                  View the payout transaction
                </a>
              ) : settledLog?.transactionHash ? (
                <p className="m-0 text-xs opacity-70 break-all">Payout tx: {settledLog.transactionHash}</p>
              ) : null}
            </div>
          )}

          {status === GameStatus.Cancelled && (
            <p className="m-0 text-center">Player 1 cancelled this game before anyone joined.</p>
          )}
          {status === GameStatus.Refunded && (
            <p className="m-0 text-center">
              Chainlink didn&apos;t answer within an hour, so both players were refunded.
            </p>
          )}
        </div>
      </div>

      <Link href="/" className="link">
        Back to start
      </Link>
    </div>
  );
};

const STATUS_BADGES: Record<GameStatus, { label: string; className: string }> = {
  [GameStatus.None]: { label: "Unknown", className: "badge-ghost" },
  [GameStatus.Open]: { label: "Waiting for opponent", className: "badge-info" },
  [GameStatus.Flipping]: { label: "Flipping…", className: "badge-warning" },
  [GameStatus.Settled]: { label: "Settled", className: "badge-success" },
  [GameStatus.Cancelled]: { label: "Cancelled", className: "badge-ghost" },
  [GameStatus.Refunded]: { label: "Refunded", className: "badge-ghost" },
};

const StatusBadge = ({ status }: { status: GameStatus }) => {
  const { label, className } = STATUS_BADGES[status];
  return <span className={`badge ${className}`}>{label}</span>;
};

const PlayerSlot = ({
  title,
  address,
  you,
  winner,
}: {
  title: string;
  address?: string;
  you: boolean;
  winner: boolean;
}) => {
  const { targetNetwork } = useTargetNetwork();
  return (
    <div className={`rounded-box p-3 bg-base-200 ${winner ? "ring-2 ring-success" : ""}`}>
      <p className="m-0 text-sm font-semibold">
        {title} {you && <span className="badge badge-sm badge-primary">you</span>}{" "}
        {winner && <span className="badge badge-sm badge-success">winner</span>}
      </p>
      <div className="mt-2">
        {address ? (
          <Address address={address as `0x${string}`} chain={targetNetwork} size="sm" />
        ) : (
          <span className="opacity-60">Waiting…</span>
        )}
      </div>
    </div>
  );
};

const Message = ({ title, spinner }: { title: string; spinner?: boolean }) => (
  <div className="flex flex-col items-center grow pt-20 gap-4">
    {spinner && <span className="loading loading-spinner loading-lg" />}
    <p className="text-xl m-0">{title}</p>
    <Link href="/" className="link">
      Back to start
    </Link>
  </div>
);

export default GamePage;
