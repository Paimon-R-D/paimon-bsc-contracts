// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LzOptionsLib
/// @notice Correctly encodes LayerZero V2 Type 3 executor options
/// @dev Format derived from official OptionsBuilder + ExecutorOptions:
///      [TYPE_3 header (uint16)] + [workerID (uint8)][optionSize (uint16)][optionType (uint8)][option data]
///      For lzReceive: workerID=1, optionType=1, option=gas(uint128) [+value(uint128)]
library LzOptionsLib {
    uint16 internal constant TYPE_3 = 3;
    uint8 internal constant EXECUTOR_WORKER_ID = 1;
    uint8 internal constant OPTION_TYPE_LZRECEIVE = 1;
    uint8 internal constant OPTION_TYPE_LZCOMPOSE = 3;

    /// @notice Build LayerZero executor options for lzReceive (no native value)
    /// @param gasLimit Gas limit for the destination execution
    /// @return options Correctly encoded Type 3 options
    function buildLzReceiveOptions(uint128 gasLimit) internal pure returns (bytes memory) {
        // option = abi.encodePacked(uint128(gas)) → 16 bytes
        // optionSize = 1 (optionType) + 16 (gas) = 17
        return abi.encodePacked(
            TYPE_3, // uint16(3)
            EXECUTOR_WORKER_ID, // uint8(1)
            uint16(17), // optionSize: 1 + 16
            OPTION_TYPE_LZRECEIVE, // uint8(1)
            gasLimit // uint128
        );
    }

    /// @notice Build LayerZero executor options with native value transfer
    /// @param gasLimit Gas limit for the destination execution
    /// @param nativeValue Native token amount to transfer with message
    /// @return options Correctly encoded Type 3 options
    function buildLzReceiveOptionsWithValue(uint128 gasLimit, uint128 nativeValue)
        internal
        pure
        returns (bytes memory)
    {
        // option = abi.encodePacked(uint128(gas), uint128(value)) → 32 bytes
        // optionSize = 1 (optionType) + 32 (gas + value) = 33
        return abi.encodePacked(
            TYPE_3, // uint16(3)
            EXECUTOR_WORKER_ID, // uint8(1)
            uint16(33), // optionSize: 1 + 16 + 16
            OPTION_TYPE_LZRECEIVE, // uint8(1)
            gasLimit, // uint128
            nativeValue // uint128
        );
    }

    /// @notice Build options with lzReceive + lzCompose gas allocation
    /// @dev Required for Stargate compose: Phase 1 (token credit) + Phase 2 (business logic)
    /// @param receiveGas Gas for lzReceive (token delivery + sendCompose call)
    /// @param composeGas Gas for lzCompose (business logic execution)
    /// @return options Correctly encoded Type 3 options with both phases
    function buildComposeOptions(uint128 receiveGas, uint128 composeGas)
        internal
        pure
        returns (bytes memory)
    {
        // lzReceive option: optionType(1) + gas(16) = 17 bytes
        // lzCompose option: optionType(1) + index(2) + gas(16) = 19 bytes
        return abi.encodePacked(
            TYPE_3,
            // lzReceive option
            EXECUTOR_WORKER_ID, // uint8(1)
            uint16(17), // optionSize: 1 + 16
            OPTION_TYPE_LZRECEIVE, // uint8(1)
            receiveGas, // uint128
            // lzCompose option (index 0)
            EXECUTOR_WORKER_ID, // uint8(1)
            uint16(19), // optionSize: 1 + 2 + 16
            OPTION_TYPE_LZCOMPOSE, // uint8(3)
            uint16(0), // compose index
            composeGas // uint128
        );
    }

    /// @notice Build compose options with native value transfer in compose phase
    /// @param receiveGas Gas for lzReceive
    /// @param composeGas Gas for lzCompose
    /// @param composeValue Native value to pass to lzCompose
    function buildComposeOptionsWithValue(uint128 receiveGas, uint128 composeGas, uint128 composeValue)
        internal
        pure
        returns (bytes memory)
    {
        // lzCompose option with value: optionType(1) + index(2) + gas(16) + value(16) = 35 bytes
        return abi.encodePacked(
            TYPE_3,
            // lzReceive option
            EXECUTOR_WORKER_ID,
            uint16(17),
            OPTION_TYPE_LZRECEIVE,
            receiveGas,
            // lzCompose option with value (index 0)
            EXECUTOR_WORKER_ID,
            uint16(35), // optionSize: 1 + 2 + 16 + 16
            OPTION_TYPE_LZCOMPOSE,
            uint16(0),
            composeGas,
            composeValue
        );
    }
}
