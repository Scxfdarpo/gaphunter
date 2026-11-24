// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/**
 * @notice Test double for the Reactive system contract. Its runtime code is
 *         etched onto the real system address (0x8888...8888) inside tests so
 *         subscriptions and callback requests can be recorded and asserted.
 */
contract MockSystemRecorder {
    uint256 public subscribeCalls;
    uint256 public callbackCalls;
    uint256 public lastChainId;
    address public lastRecipient;
    uint64 public lastGasLimit;
    bytes public lastPayload;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackCalls++;
        lastChainId = config_.chainId;
        lastRecipient = config_.recipient;
        lastGasLimit = config_.gasLimit;
        lastPayload = config_.payload;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}
