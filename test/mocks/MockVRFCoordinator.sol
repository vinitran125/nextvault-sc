// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVRFCoordinatorV2Plus, VRFV2PlusClient} from "../../src/interfaces/IVRFCoordinatorV2Plus.sol";

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

contract MockVRFCoordinator is IVRFCoordinatorV2Plus {
    uint256 private nextRequestId = 1;
    mapping(uint256 => address) public consumerOf;

    function addConsumer(uint256, address) external {}

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        consumerOf[requestId] = msg.sender;
    }

    function fulfill(uint256 requestId, uint256 randomWord) external {
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomWord;
        IVRFConsumer(consumerOf[requestId]).rawFulfillRandomWords(requestId, randomWords);
    }
}
