"use client";

import { parseUnits } from "viem";
import { hardhat } from "viem/chains";
import { useAccount, useWriteContract } from "wagmi";
import { useTargetNetwork, useTransactor } from "~~/hooks/scaffold-eth";
import { useAllContracts } from "~~/utils/scaffold-eth/contractsData";

/**
 * Local-anvil-only helpers. MockUSDC and LocalVRFCoordinator only exist in the local deployment, so they are
 * looked up at runtime instead of through the typed scaffold hooks (which would break the Sepolia build).
 */
const useLocalMock = (name: "MockUSDC" | "LocalVRFCoordinator") => {
  const { targetNetwork } = useTargetNetwork();
  const contracts = useAllContracts();
  return targetNetwork.id === hardhat.id ? contracts[name] : undefined;
};

const useLocalWrite = () => {
  const { writeContractAsync, isPending } = useWriteContract();
  const transact = useTransactor();
  const write = async (params: Parameters<typeof writeContractAsync>[0]) => {
    try {
      await transact(() => writeContractAsync(params));
    } catch {
      // useTransactor already showed the error
    }
  };
  return { write, isPending };
};

export const MintTestUsdcButton = () => {
  const mockUsdc = useLocalMock("MockUSDC");
  const { address } = useAccount();
  const { write, isPending } = useLocalWrite();
  if (!mockUsdc || !address) return null;

  return (
    <button
      className="btn btn-sm btn-outline"
      disabled={isPending}
      onClick={() =>
        write({
          address: mockUsdc.address,
          abi: mockUsdc.abi,
          functionName: "mint",
          args: [address, parseUnits("100", 6)],
        })
      }
    >
      Mint 100 test USDC (local)
    </button>
  );
};

export const AnswerFlipButton = ({ requestId }: { requestId: bigint }) => {
  const coordinator = useLocalMock("LocalVRFCoordinator");
  const { write, isPending } = useLocalWrite();
  if (!coordinator) return null;

  return (
    <button
      className="btn btn-sm btn-outline"
      disabled={isPending}
      onClick={() =>
        write({ address: coordinator.address, abi: coordinator.abi, functionName: "fulfill", args: [requestId] })
      }
    >
      Answer flip (local VRF)
    </button>
  );
};
