// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DeployHelpers.s.sol";
import { IVRFSubscriptionV2Plus } from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol";
import { CoinFlip } from "../contracts/CoinFlip.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { LocalVRFCoordinator } from "../contracts/mocks/LocalVRFCoordinator.sol";

/**
 * @notice Deploys CoinFlip.
 *  - Sepolia: uses Chainlink's VRF v2.5 coordinator and Circle USDC, and adds the contract as a consumer
 *    of VRF_SUBSCRIPTION_ID (the deployer must own that subscription).
 *      VRF_SUBSCRIPTION_ID=<id> yarn deploy --file DeployCoinFlip.s.sol --network sepolia
 *  - Local anvil: deploys LocalVRFCoordinator (answer flips from the Debug page) and a mintable MockUSDC.
 */
contract DeployCoinFlip is ScaffoldETHDeploy {
    // https://docs.chain.link/vrf/v2-5/supported-networks#ethereum-sepolia-testnet
    address constant SEPOLIA_VRF_COORDINATOR = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 constant SEPOLIA_KEY_HASH = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    // https://developers.circle.com/stablecoins/usdc-contract-addresses
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    // Measured ~108k gas for the callback with real Sepolia USDC (test/CoinFlip.fork.t.sol).
    uint32 constant CALLBACK_GAS_LIMIT = 250_000;
    uint16 constant REQUEST_CONFIRMATIONS = 3;

    function run() external ScaffoldEthDeployerRunner {
        if (block.chainid == 11155111) {
            uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
            CoinFlip flip = new CoinFlip(
                SEPOLIA_VRF_COORDINATOR,
                SEPOLIA_USDC,
                subId,
                SEPOLIA_KEY_HASH,
                CALLBACK_GAS_LIMIT,
                REQUEST_CONFIRMATIONS,
                true
            );
            IVRFSubscriptionV2Plus(SEPOLIA_VRF_COORDINATOR).addConsumer(subId, address(flip));
            console.log("CoinFlip deployed and added to VRF subscription:", address(flip));
        } else if (block.chainid == 31337) {
            LocalVRFCoordinator coordinator = new LocalVRFCoordinator();
            MockUSDC usdc = new MockUSDC();
            new CoinFlip(
                address(coordinator), address(usdc), 0, bytes32(0), CALLBACK_GAS_LIMIT, REQUEST_CONFIRMATIONS, true
            );
        } else {
            revert InvalidChain();
        }
    }
}
