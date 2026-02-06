// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library PythStructs {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint publishTime;
    }
}

interface IPyth {
    /// @notice Returns the price of a price feed without any sanity checks.
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory price);
}
