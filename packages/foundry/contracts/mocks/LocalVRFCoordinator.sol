// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { VRFConsumerBaseV2Plus } from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import { VRFV2PlusClient } from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @notice Local-anvil stand-in for the VRF v2.5 coordinator, for frontend development only.
 * @dev Chainlink's VRFCoordinatorV2_5Mock derives subscription IDs from the previous blockhash, so the ID a
 *      forge script sees in simulation differs from the one created on-chain and the deploy breaks. This mock
 *      has no subscriptions: any request is accepted, and anyone can answer it with `fulfill` (e.g. from the
 *      Scaffold-ETH Debug page). Unit tests use Chainlink's official mock instead.
 */
contract LocalVRFCoordinator {
    uint256 public nextRequestId = 1;
    mapping(uint256 requestId => address consumer) public consumerOf;

    event RandomWordsRequested(uint256 indexed requestId, address indexed consumer);
    event RandomWordsFulfilled(uint256 indexed requestId, uint256 randomWord);

    error UnknownRequest(uint256 requestId);

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        consumerOf[requestId] = msg.sender;
        emit RandomWordsRequested(requestId, msg.sender);
    }

    /// @notice Answer `requestId` with a pseudo-random word (not secure; local use only).
    function fulfill(uint256 requestId) external {
        address consumer = consumerOf[requestId];
        if (consumer == address(0)) revert UnknownRequest(requestId);
        delete consumerOf[requestId];

        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256(abi.encode(requestId, block.prevrandao, block.timestamp)));
        VRFConsumerBaseV2Plus(consumer).rawFulfillRandomWords(requestId, words);
        emit RandomWordsFulfilled(requestId, words[0]);
    }
}
