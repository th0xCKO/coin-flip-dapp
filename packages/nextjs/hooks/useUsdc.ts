import { erc20Abi } from "viem";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { useDeployedContractInfo, useScaffoldReadContract, useTransactor } from "~~/hooks/scaffold-eth";
import { BUY_IN } from "~~/utils/coinflip";

/**
 * The USDC token CoinFlip escrows (Circle USDC on Sepolia, MockUSDC locally), read from `CoinFlip.usdc()`,
 * plus the connected wallet's balance and allowance to CoinFlip.
 */
export const useUsdc = () => {
  const { address: account } = useAccount();
  const { data: coinFlip } = useDeployedContractInfo({ contractName: "CoinFlip" });
  const { data: usdcAddress } = useScaffoldReadContract({ contractName: "CoinFlip", functionName: "usdc" });

  const enabled = Boolean(account && usdcAddress && coinFlip);
  const { data: balance, refetch: refetchBalance } = useReadContract({
    address: usdcAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled, refetchInterval: 4000 },
  });
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: usdcAddress,
    abi: erc20Abi,
    functionName: "allowance",
    args: account && coinFlip ? [account, coinFlip.address] : undefined,
    // Polled too, so an allowance spent elsewhere (another tab) is noticed before we skip the approve step.
    query: { enabled, refetchInterval: 4000 },
  });

  const { writeContractAsync } = useWriteContract();
  const transact = useTransactor();

  /**
   * Approves exactly one buy-in if the current allowance is short. Returns false if the approval did not go
   * through (useTransactor has already shown the error toast).
   */
  const ensureBuyInAllowance = async () => {
    if (!usdcAddress || !coinFlip) return false;
    if ((allowance ?? 0n) >= BUY_IN) return true;
    try {
      // useTransactor returns undefined without throwing when no wallet client is available.
      const hash = await transact(() =>
        writeContractAsync({
          address: usdcAddress,
          abi: erc20Abi,
          functionName: "approve",
          args: [coinFlip.address, BUY_IN],
        }),
      );
      return hash !== undefined;
    } catch {
      return false;
    } finally {
      await refetchAllowance();
    }
  };

  return {
    usdcAddress,
    balance,
    hasBuyIn: balance !== undefined && balance >= BUY_IN,
    ensureBuyInAllowance,
    refetch: () => Promise.all([refetchBalance(), refetchAllowance()]),
  };
};
