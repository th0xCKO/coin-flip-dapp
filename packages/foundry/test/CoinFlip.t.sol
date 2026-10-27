// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { VRFCoordinatorV2_5Mock } from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { CoinFlip } from "../contracts/CoinFlip.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";

contract CoinFlipTest is Test {
    uint32 constant CALLBACK_GAS_LIMIT = 250_000;
    bytes32 constant KEY_HASH = keccak256("test-key-hash");

    VRFCoordinatorV2_5Mock coordinator;
    MockUSDC usdc;
    CoinFlip flip;
    uint256 subId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant BUY_IN = 10e6;

    function setUp() public {
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1 gwei, 4e15);
        subId = coordinator.createSubscription();
        coordinator.fundSubscriptionWithNative{ value: 100 ether }(subId);

        usdc = new MockUSDC();
        flip = new CoinFlip(address(coordinator), address(usdc), subId, KEY_HASH, CALLBACK_GAS_LIMIT, 3, true);
        coordinator.addConsumer(subId, address(flip));

        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < players.length; i++) {
            usdc.mint(players[i], 100e6);
            vm.prank(players[i]);
            usdc.approve(address(flip), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _create(address who, CoinFlip.Side side) internal returns (uint256 id) {
        vm.prank(who);
        id = flip.createGame(side);
    }

    function _join(address who, uint256 id) internal returns (uint256 requestId) {
        vm.prank(who);
        flip.joinGame(id);
        requestId = flip.getGame(id).requestId;
    }

    function _fulfill(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        coordinator.fulfillRandomWordsWithOverride(requestId, address(flip), words);
    }

    // ---------------------------------------------------------------- create

    function test_CreateGame_TakesBuyInAndRecordsSide() public {
        uint256 id = _create(alice, CoinFlip.Side.Tails);

        assertEq(id, 1);
        assertEq(flip.nextGameId(), 2);
        assertEq(usdc.balanceOf(address(flip)), BUY_IN);
        assertEq(usdc.balanceOf(alice), 90e6);

        CoinFlip.Game memory g = flip.getGame(id);
        assertEq(g.player1, alice);
        assertEq(uint8(g.player1Side), uint8(CoinFlip.Side.Tails));
        assertEq(uint8(g.status), uint8(CoinFlip.Status.Open));
        assertEq(uint8(flip.player2Side(id)), uint8(CoinFlip.Side.Heads));
    }

    function test_CreateGame_IdsAreSequential() public {
        assertEq(_create(alice, CoinFlip.Side.Heads), 1);
        assertEq(_create(bob, CoinFlip.Side.Heads), 2);
        assertEq(_create(alice, CoinFlip.Side.Tails), 3);
    }

    function test_RevertWhen_CreateWithoutApproval() public {
        address dave = makeAddr("dave");
        usdc.mint(dave, 100e6);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(flip), 0, BUY_IN)
        );
        flip.createGame(CoinFlip.Side.Heads);
    }

    function test_RevertWhen_CreateWithoutBalance() public {
        address dave = makeAddr("dave");
        vm.startPrank(dave);
        usdc.approve(address(flip), BUY_IN);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, dave, 0, BUY_IN));
        flip.createGame(CoinFlip.Side.Heads);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- join

    function test_JoinGame_TakesBuyInAndRequestsRandomness() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        uint256 requestId = _join(bob, id);

        CoinFlip.Game memory g = flip.getGame(id);
        assertEq(g.player2, bob);
        assertEq(uint8(g.status), uint8(CoinFlip.Status.Flipping));
        assertEq(g.joinedAt, block.timestamp);
        assertGt(requestId, 0);
        assertEq(flip.gameIdByRequest(requestId), id);
        assertEq(usdc.balanceOf(address(flip)), 2 * BUY_IN);
    }

    function test_RevertWhen_JoinOwnGame() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        vm.prank(alice);
        vm.expectRevert(CoinFlip.CannotJoinOwnGame.selector);
        flip.joinGame(id);
    }

    function test_RevertWhen_JoinFullGame() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        _join(bob, id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CoinFlip.GameNotOpen.selector, id));
        flip.joinGame(id);
    }

    function test_RevertWhen_JoinNonexistentGame() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoinFlip.GameNotOpen.selector, 42));
        flip.joinGame(42);
    }

    function test_RevertWhen_JoinCancelledGame() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        vm.prank(alice);
        flip.cancelGame(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoinFlip.GameNotOpen.selector, id));
        flip.joinGame(id);
    }

    // ---------------------------------------------------------------- settle

    function test_Settle_Player1WinsWhenResultMatchesTheirSide() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        uint256 requestId = _join(bob, id);

        vm.expectEmit(address(flip));
        emit CoinFlip.GameSettled(id, CoinFlip.Side.Heads, alice, true);
        _fulfill(requestId, 2); // even -> Heads

        CoinFlip.Game memory g = flip.getGame(id);
        assertEq(uint8(g.status), uint8(CoinFlip.Status.Settled));
        assertEq(uint8(g.result), uint8(CoinFlip.Side.Heads));
        assertEq(g.winner, alice);
        assertEq(g.settledBlock, block.number);
        assertEq(usdc.balanceOf(alice), 110e6);
        assertEq(usdc.balanceOf(bob), 90e6);
        assertEq(usdc.balanceOf(address(flip)), 0);
    }

    function test_Settle_Player2WinsWhenResultIsOpposite() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        uint256 requestId = _join(bob, id);

        _fulfill(requestId, 7); // odd -> Tails

        CoinFlip.Game memory g = flip.getGame(id);
        assertEq(uint8(g.result), uint8(CoinFlip.Side.Tails));
        assertEq(g.winner, bob);
        assertEq(usdc.balanceOf(alice), 90e6);
        assertEq(usdc.balanceOf(bob), 110e6);
    }

    function testFuzz_Settle_WinnerTakesPotAndFundsAreConserved(uint256 word, bool aliceTakesTails) public {
        CoinFlip.Side aliceSide = aliceTakesTails ? CoinFlip.Side.Tails : CoinFlip.Side.Heads;
        uint256 id = _create(alice, aliceSide);
        uint256 requestId = _join(bob, id);
        _fulfill(requestId, word);

        CoinFlip.Game memory g = flip.getGame(id);
        CoinFlip.Side expected = CoinFlip.Side(word % 2);
        assertEq(uint8(g.result), uint8(expected));
        assertEq(g.winner, expected == aliceSide ? alice : bob);
        assertEq(usdc.balanceOf(g.winner), 110e6);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), 200e6);
        assertEq(usdc.balanceOf(address(flip)), 0);
    }

    function test_Settle_ConcurrentGamesAreIndependent() public {
        uint256 g1 = _create(alice, CoinFlip.Side.Heads);
        uint256 g2 = _create(carol, CoinFlip.Side.Tails);
        uint256 r1 = _join(bob, g1);
        uint256 r2 = _join(alice, g2);

        _fulfill(r2, 1); // Tails -> carol wins g2
        _fulfill(r1, 1); // Tails -> bob wins g1

        assertEq(flip.getGame(g1).winner, bob);
        assertEq(flip.getGame(g2).winner, carol);
        assertEq(usdc.balanceOf(alice), 80e6);
        assertEq(usdc.balanceOf(bob), 110e6);
        assertEq(usdc.balanceOf(carol), 110e6);
        assertEq(usdc.balanceOf(address(flip)), 0);
    }

    function test_RevertWhen_NonCoordinatorFulfills() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        uint256 requestId = _join(bob, id);
        uint256[] memory words = new uint256[](1);

        vm.prank(bob);
        vm.expectRevert();
        flip.rawFulfillRandomWords(requestId, words);
    }

    // ---------------------------------------------------------------- payout failure

    function test_Settle_BlockedWinnerIsCreditedAndCanClaimLater() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        uint256 requestId = _join(bob, id);
        usdc.setBlocked(alice, true);

        vm.expectEmit(address(flip));
        emit CoinFlip.GameSettled(id, CoinFlip.Side.Heads, alice, false);
        _fulfill(requestId, 0);

        // The callback did not revert: game settled, pot held for alice.
        assertEq(uint8(flip.getGame(id).status), uint8(CoinFlip.Status.Settled));
        assertEq(flip.claimable(alice), 2 * BUY_IN);
        assertEq(usdc.balanceOf(address(flip)), 2 * BUY_IN);

        usdc.setBlocked(alice, false);
        vm.prank(alice);
        flip.claim();
        assertEq(flip.claimable(alice), 0);
        assertEq(usdc.balanceOf(alice), 110e6);
        assertEq(usdc.balanceOf(address(flip)), 0);
    }

    function test_RevertWhen_ClaimWithNothingOwed() public {
        vm.prank(alice);
        vm.expectRevert(CoinFlip.NothingToClaim.selector);
        flip.claim();
    }

    // ---------------------------------------------------------------- cancel

    function test_Cancel_RefundsPlayer1() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        vm.prank(alice);
        flip.cancelGame(id);

        assertEq(uint8(flip.getGame(id).status), uint8(CoinFlip.Status.Cancelled));
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usdc.balanceOf(address(flip)), 0);
    }

    function test_RevertWhen_CancelByNonCreator() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        vm.prank(bob);
        vm.expectRevert(CoinFlip.NotPlayer1.selector);
        flip.cancelGame(id);
    }

    function test_RevertWhen_CancelAfterJoin() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        _join(bob, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoinFlip.GameNotOpen.selector, id));
        flip.cancelGame(id);
    }

    function test_RevertWhen_CancelTwice() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        vm.startPrank(alice);
        flip.cancelGame(id);
        vm.expectRevert(abi.encodeWithSelector(CoinFlip.GameNotOpen.selector, id));
        flip.cancelGame(id);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- refund

    function test_Refund_AfterTimeoutReturnsBothBuyIns() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        _join(bob, id);
        vm.warp(block.timestamp + flip.FLIP_TIMEOUT());

        vm.prank(carol); // anyone can trigger it
        flip.refundGame(id);

        assertEq(uint8(flip.getGame(id).status), uint8(CoinFlip.Status.Refunded));
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usdc.balanceOf(bob), 100e6);
        assertEq(usdc.balanceOf(address(flip)), 0);
    }

    function test_RevertWhen_RefundBeforeTimeout() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        _join(bob, id);
        uint256 refundableAt = block.timestamp + flip.FLIP_TIMEOUT();
        vm.warp(refundableAt - 1);

        vm.expectRevert(abi.encodeWithSelector(CoinFlip.TimeoutNotReached.selector, refundableAt));
        flip.refundGame(id);
    }

    function test_RevertWhen_RefundOpenOrSettledGame() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        vm.expectRevert(abi.encodeWithSelector(CoinFlip.GameNotFlipping.selector, id));
        flip.refundGame(id);

        uint256 requestId = _join(bob, id);
        _fulfill(requestId, 0);
        vm.warp(block.timestamp + flip.FLIP_TIMEOUT());
        vm.expectRevert(abi.encodeWithSelector(CoinFlip.GameNotFlipping.selector, id));
        flip.refundGame(id);
    }

    function test_Refund_LateVrfAnswerIsIgnored() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        uint256 requestId = _join(bob, id);
        vm.warp(block.timestamp + flip.FLIP_TIMEOUT());
        flip.refundGame(id);

        _fulfill(requestId, 0); // would have made alice win

        CoinFlip.Game memory g = flip.getGame(id);
        assertEq(uint8(g.status), uint8(CoinFlip.Status.Refunded));
        assertEq(g.winner, address(0));
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usdc.balanceOf(bob), 100e6);
    }

    function test_Refund_BlockedPlayerIsCreditedOtherIsPaid() public {
        uint256 id = _create(alice, CoinFlip.Side.Heads);
        _join(bob, id);
        vm.warp(block.timestamp + flip.FLIP_TIMEOUT());
        usdc.setBlocked(bob, true);

        flip.refundGame(id);

        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(flip.claimable(bob), BUY_IN);
        assertEq(usdc.balanceOf(address(flip)), BUY_IN);
    }

    // ---------------------------------------------------------------- admin

    function test_OwnerCanUpdateVrfConfig() public {
        flip.setVrfConfig(7, bytes32(uint256(1)), 300_000, 5, false);
        assertEq(flip.subscriptionId(), 7);
        assertEq(flip.callbackGasLimit(), 300_000);
        assertEq(flip.requestConfirmations(), 5);
        assertFalse(flip.nativePayment());
    }

    function test_RevertWhen_NonOwnerUpdatesVrfConfig() public {
        vm.prank(alice);
        vm.expectRevert("Only callable by owner");
        flip.setVrfConfig(7, bytes32(uint256(1)), 300_000, 5, false);
    }
}
