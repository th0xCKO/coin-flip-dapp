// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { VRFCoordinatorV2_5Mock } from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CoinFlip } from "../contracts/CoinFlip.sol";

/// @dev Runs against a Sepolia fork with Circle's real USDC to check the VRF callback (which does the
///      USDC payout) fits inside the callback gas limit. Skipped unless SEPOLIA_RPC_URL is set.
///      SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-contract Fork -vv
contract CoinFlipForkTest is Test {
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    uint32 constant CALLBACK_GAS_LIMIT = 250_000;

    function test_Fork_CallbackFitsGasLimitWithRealUsdc() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        VRFCoordinatorV2_5Mock coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1 gwei, 4e15);
        uint256 subId = coordinator.createSubscription();
        coordinator.fundSubscriptionWithNative{ value: 100 ether }(subId);
        CoinFlip flip = new CoinFlip(address(coordinator), SEPOLIA_USDC, subId, bytes32(0), CALLBACK_GAS_LIMIT, 3, true);
        coordinator.addConsumer(subId, address(flip));

        IERC20 usdc = IERC20(SEPOLIA_USDC);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        deal(SEPOLIA_USDC, alice, 10e6);
        deal(SEPOLIA_USDC, bob, 10e6);

        vm.startPrank(alice);
        usdc.approve(address(flip), 10e6);
        uint256 id = flip.createGame(CoinFlip.Side.Heads);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(flip), 10e6);
        flip.joinGame(id);
        vm.stopPrank();

        uint256[] memory words = new uint256[](1); // 0 -> Heads -> alice wins
        uint256 requestId = flip.getGame(id).requestId;

        // Measure the callback on its own, as the coordinator would call it.
        vm.prank(address(coordinator));
        uint256 gasBefore = gasleft();
        flip.rawFulfillRandomWords{ gas: CALLBACK_GAS_LIMIT }(requestId, words);
        uint256 used = gasBefore - gasleft();
        console.log("callback gas used:", used);

        assertEq(uint8(flip.getGame(id).status), uint8(CoinFlip.Status.Settled));
        assertEq(usdc.balanceOf(alice), 20e6, "pot paid in real USDC");
        assertEq(flip.claimable(alice), 0, "payout not deferred");
        assertLt(used, CALLBACK_GAS_LIMIT / 2, "keep at least 2x headroom");
    }
}
