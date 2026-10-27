// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { VRFConsumerBaseV2Plus } from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import { VRFV2PlusClient } from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CoinFlip
/// @notice Two-player USDC coin flip. Player 1 opens a game with a side and a 10 USDC buy-in;
///         player 2 joins by game ID, takes the opposite side and matches the buy-in. Joining
///         requests a Chainlink VRF v2.5 random word, and the VRF callback pays the pot to the winner.
/// @dev Trust model: the owner can only change VRF settings. There is no function that moves escrowed
///      USDC other than the game rules. Note the owner can repoint the VRF coordinator
///      (inherited `setCoordinator`), which would let a malicious owner choose outcomes; acceptable
///      for a testnet workshop, documented here so nobody assumes otherwise.
contract CoinFlip is VRFConsumerBaseV2Plus, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Side {
        Heads,
        Tails
    }

    enum Status {
        None, // game ID never used
        Open, // waiting for player 2
        Flipping, // both deposited, waiting for VRF
        Settled, // winner decided and paid (or credited to `claimable`)
        Cancelled, // player 1 withdrew before anyone joined
        Refunded // VRF did not answer within FLIP_TIMEOUT; both refunded
    }

    struct Game {
        address player1;
        address player2;
        Side player1Side;
        Side result;
        Status status;
        uint64 joinedAt;
        /// @dev Lets a frontend fetch the GameSettled log (and so the payout tx) from one block, no indexer needed.
        uint64 settledBlock;
        address winner;
        uint256 requestId;
    }

    /// @notice 10 USDC (6 decimals).
    uint256 public constant BUY_IN = 10e6;
    uint256 public constant POT = 2 * BUY_IN;
    /// @notice After this long without a VRF answer, anyone can refund both players.
    uint256 public constant FLIP_TIMEOUT = 1 hours;

    IERC20 public immutable usdc;

    uint256 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit;
    uint16 public requestConfirmations;
    bool public nativePayment;

    /// @notice ID the next created game will get. IDs start at 1 so 0 means "no game".
    uint256 public nextGameId = 1;

    mapping(uint256 gameId => Game) private games;
    mapping(uint256 requestId => uint256 gameId) public gameIdByRequest;
    /// @notice USDC owed to an address whose automatic transfer failed; withdraw with `claim()`.
    mapping(address account => uint256 amount) public claimable;

    event GameCreated(uint256 indexed gameId, address indexed player1, Side player1Side);
    event GameJoined(uint256 indexed gameId, address indexed player2, uint256 requestId);
    event GameSettled(uint256 indexed gameId, Side result, address indexed winner, bool paid);
    event GameCancelled(uint256 indexed gameId);
    event GameRefunded(uint256 indexed gameId);
    event PaymentDeferred(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event VrfConfigUpdated(
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    );

    error GameNotOpen(uint256 gameId);
    error GameNotFlipping(uint256 gameId);
    error CannotJoinOwnGame();
    error NotPlayer1();
    error TimeoutNotReached(uint256 refundableAt);
    error NothingToClaim();

    constructor(
        address vrfCoordinator,
        address usdc_,
        uint256 subscriptionId_,
        bytes32 keyHash_,
        uint32 callbackGasLimit_,
        uint16 requestConfirmations_,
        bool nativePayment_
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        usdc = IERC20(usdc_);
        _setVrfConfig(subscriptionId_, keyHash_, callbackGasLimit_, requestConfirmations_, nativePayment_);
    }

    // ---------------------------------------------------------------- player actions

    /// @notice Open a game on `side`. Requires a prior USDC approval of BUY_IN.
    function createGame(Side side) external nonReentrant returns (uint256 gameId) {
        gameId = nextGameId++;
        Game storage g = games[gameId];
        g.player1 = msg.sender;
        g.player1Side = side;
        g.status = Status.Open;

        usdc.safeTransferFrom(msg.sender, address(this), BUY_IN);
        emit GameCreated(gameId, msg.sender, side);
    }

    /// @notice Join an open game on the opposite side. Requires a prior USDC approval of BUY_IN.
    function joinGame(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != Status.Open) revert GameNotOpen(gameId);
        if (msg.sender == g.player1) revert CannotJoinOwnGame();

        g.player2 = msg.sender;
        g.status = Status.Flipping;
        g.joinedAt = uint64(block.timestamp);

        usdc.safeTransferFrom(msg.sender, address(this), BUY_IN);

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({ nativePayment: nativePayment }))
            })
        );
        g.requestId = requestId;
        gameIdByRequest[requestId] = gameId;

        emit GameJoined(gameId, msg.sender, requestId);
    }

    /// @notice Player 1 takes their buy-in back before anyone has joined.
    function cancelGame(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != Status.Open) revert GameNotOpen(gameId);
        if (msg.sender != g.player1) revert NotPlayer1();

        g.status = Status.Cancelled;
        usdc.safeTransfer(msg.sender, BUY_IN);
        emit GameCancelled(gameId);
    }

    /// @notice If VRF has not answered within FLIP_TIMEOUT of joining, anyone can refund both players.
    ///         A late VRF answer for a refunded game is ignored.
    function refundGame(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        if (g.status != Status.Flipping) revert GameNotFlipping(gameId);
        uint256 refundableAt = uint256(g.joinedAt) + FLIP_TIMEOUT;
        if (block.timestamp < refundableAt) revert TimeoutNotReached(refundableAt);

        g.status = Status.Refunded;
        _pay(g.player1, BUY_IN);
        _pay(g.player2, BUY_IN);
        emit GameRefunded(gameId);
    }

    /// @notice Withdraw USDC whose automatic transfer failed (e.g. the recipient was blocked at the time).
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        usdc.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------- VRF callback

    /// @dev Must never revert: the coordinator does not retry a failed callback, so a revert here
    ///      would leave the game stuck until the refund timeout.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 gameId = gameIdByRequest[requestId];
        Game storage g = games[gameId];
        if (g.status != Status.Flipping || g.requestId != requestId) return; // refunded or unknown

        Side result = Side(randomWords[0] % 2);
        address winner = result == g.player1Side ? g.player1 : g.player2;

        g.result = result;
        g.winner = winner;
        g.status = Status.Settled;
        g.settledBlock = uint64(block.number);

        bool paid = _pay(winner, POT);
        emit GameSettled(gameId, result, winner, paid);
    }

    // ---------------------------------------------------------------- admin

    function setVrfConfig(
        uint256 subscriptionId_,
        bytes32 keyHash_,
        uint32 callbackGasLimit_,
        uint16 requestConfirmations_,
        bool nativePayment_
    ) external onlyOwner {
        _setVrfConfig(subscriptionId_, keyHash_, callbackGasLimit_, requestConfirmations_, nativePayment_);
    }

    // ---------------------------------------------------------------- views

    function getGame(uint256 gameId) external view returns (Game memory) {
        return games[gameId];
    }

    /// @notice The side player 2 gets (or got) in `gameId`.
    function player2Side(uint256 gameId) external view returns (Side) {
        return games[gameId].player1Side == Side.Heads ? Side.Tails : Side.Heads;
    }

    // ---------------------------------------------------------------- internal

    /// @dev Push USDC to `to`; if the transfer reverts or returns false, credit `claimable` instead
    ///      so one blocked recipient can never brick a payout or refund.
    function _pay(address to, uint256 amount) private returns (bool paid) {
        try usdc.transfer(to, amount) returns (bool ok) {
            paid = ok;
        } catch { }
        if (!paid) {
            claimable[to] += amount;
            emit PaymentDeferred(to, amount);
        }
    }

    function _setVrfConfig(
        uint256 subscriptionId_,
        bytes32 keyHash_,
        uint32 callbackGasLimit_,
        uint16 requestConfirmations_,
        bool nativePayment_
    ) private {
        subscriptionId = subscriptionId_;
        keyHash = keyHash_;
        callbackGasLimit = callbackGasLimit_;
        requestConfirmations = requestConfirmations_;
        nativePayment = nativePayment_;
        emit VrfConfigUpdated(subscriptionId_, keyHash_, callbackGasLimit_, requestConfirmations_, nativePayment_);
    }
}
