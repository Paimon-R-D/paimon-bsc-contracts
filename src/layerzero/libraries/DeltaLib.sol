// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DeltaLib
/// @notice Library for Delta algorithm calculations
/// @dev Used by CreditManager for credit allocation and rebalancing
library DeltaLib {

    /// @notice Basis points denominator (10000 = 100%)
    uint256 internal constant BPS_DENOMINATOR = 10000;

    /// @notice Precision for calculations (18 decimals)
    uint256 internal constant PRECISION = 1e18;

    // ========== Errors ==========

    error EmptyArray();
    error LengthMismatch(uint256 expected, uint256 actual);
    error IntegerOverflow();

    /// @notice Calculate credit allocation for a chain based on weight
    /// @param totalLiquidity Total available liquidity in the system
    /// @param chainWeight Weight of the target chain (in BPS, sum of all = 10000)
    /// @return credit Credit amount to allocate
    function calculateCredit(
        uint256 totalLiquidity,
        uint256 chainWeight
    ) internal pure returns (uint256 credit) {
        return (totalLiquidity * chainWeight) / BPS_DENOMINATOR;
    }

    /// @notice Calculate optimal weights based on historical usage
    /// @param usages Array of usage amounts per chain
    /// @param totalUsage Sum of all usage
    /// @return weights Array of optimal weights (in BPS)
    function calculateOptimalWeights(
        uint256[] memory usages,
        uint256 totalUsage
    ) internal pure returns (uint256[] memory weights) {
        if (usages.length == 0) revert EmptyArray();

        weights = new uint256[](usages.length);

        if (totalUsage == 0) {
            // Equal distribution if no usage data
            uint256 equalWeight = BPS_DENOMINATOR / usages.length;
            for (uint256 i = 0; i < usages.length; i++) {
                weights[i] = equalWeight;
            }
            return weights;
        }

        for (uint256 i = 0; i < usages.length; i++) {
            weights[i] = (usages[i] * BPS_DENOMINATOR) / totalUsage;
        }

        return weights;
    }

    /// @notice Calculate credit utilization ratio
    /// @param used Amount of credit used
    /// @param allocated Total credit allocated
    /// @return utilization Utilization ratio (0-10000 = 0-100%)
    function calculateUtilization(
        uint256 used,
        uint256 allocated
    ) internal pure returns (uint256 utilization) {
        if (allocated == 0) return BPS_DENOMINATOR; // 100% if no allocation
        return (used * BPS_DENOMINATOR) / allocated;
    }

    /// @notice Check if rebalance is needed based on utilization
    /// @param utilization Current utilization (in BPS)
    /// @param threshold Threshold for triggering rebalance (in BPS)
    /// @return needed Whether rebalance is needed
    function isRebalanceNeeded(
        uint256 utilization,
        uint256 threshold
    ) internal pure returns (bool needed) {
        return utilization >= threshold;
    }

    /// @notice Calculate rebalance amounts
    /// @param currentCredits Current credit amounts per chain
    /// @param targetWeights Target weights per chain (in BPS)
    /// @param totalLiquidity Total liquidity to distribute
    /// @return deltas Delta amounts (positive = add, negative = reduce)
    function calculateRebalanceDeltas(
        uint256[] memory currentCredits,
        uint256[] memory targetWeights,
        uint256 totalLiquidity
    ) internal pure returns (int256[] memory deltas) {
        if (currentCredits.length == 0) revert EmptyArray();
        if (currentCredits.length != targetWeights.length) {
            revert LengthMismatch(currentCredits.length, targetWeights.length);
        }

        deltas = new int256[](currentCredits.length);

        // Safe maximum for int256 conversion
        uint256 maxInt256 = uint256(type(int256).max);

        for (uint256 i = 0; i < currentCredits.length; i++) {
            uint256 targetCredit = (totalLiquidity * targetWeights[i]) / BPS_DENOMINATOR;

            // Check for overflow before converting to int256
            if (targetCredit > maxInt256 || currentCredits[i] > maxInt256) {
                revert IntegerOverflow();
            }

            deltas[i] = int256(targetCredit) - int256(currentCredits[i]);
        }

        return deltas;
    }

    /// @notice Validate weights sum to 100%
    /// @param weights Array of weights (in BPS)
    /// @return valid Whether weights sum to BPS_DENOMINATOR
    function validateWeights(
        uint256[] memory weights
    ) internal pure returns (bool valid) {
        if (weights.length == 0) return false;

        uint256 sum = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            sum += weights[i];
        }
        return sum == BPS_DENOMINATOR;
    }

    /// @notice Calculate minimum credit needed for a withdrawal amount
    /// @param withdrawAmount Amount to withdraw
    /// @param slippageBps Slippage tolerance (in BPS)
    /// @return minCredit Minimum credit required
    function calculateMinCredit(
        uint256 withdrawAmount,
        uint256 slippageBps
    ) internal pure returns (uint256 minCredit) {
        return withdrawAmount + (withdrawAmount * slippageBps) / BPS_DENOMINATOR;
    }
}
