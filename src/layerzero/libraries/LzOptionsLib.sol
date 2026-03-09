// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LzOptionsLib
/// @notice Library for building LayerZero executor options
/// @dev Shared across all LayerZero contracts to avoid code duplication
library LzOptionsLib {
    /// @notice Build LayerZero executor options for lzReceive
    /// @dev Format: [type (uint16)][gas (uint128)][value (uint128)]
    /// @param gasLimit Gas limit for the destination execution
    /// @return options Encoded options bytes
    function buildLzReceiveOptions(uint128 gasLimit) internal pure returns (bytes memory) {
        // Option type 3 = EXECUTOR_LZ_RECEIVE_OPTION
        return abi.encodePacked(
            uint16(3),      // EXECUTOR_LZ_RECEIVE_OPTION type
            gasLimit,       // gas limit
            uint128(0)      // msg.value (0 for no native transfer)
        );
    }

    /// @notice Build LayerZero executor options with native value transfer
    /// @param gasLimit Gas limit for the destination execution
    /// @param nativeValue Native token amount to transfer with message
    /// @return options Encoded options bytes
    function buildLzReceiveOptionsWithValue(
        uint128 gasLimit,
        uint128 nativeValue
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(3),      // EXECUTOR_LZ_RECEIVE_OPTION type
            gasLimit,
            nativeValue
        );
    }
}
