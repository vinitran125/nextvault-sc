// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

library VRFV2PlusClient {
    bytes4 internal constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function argsToBytes(ExtraArgsV1 memory extraArgs) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, extraArgs);
    }
}

interface IVRFCoordinatorV2Plus {
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata request)
        external
        returns (uint256 requestId);

    function addConsumer(uint256 subscriptionId, address consumer) external;
}
