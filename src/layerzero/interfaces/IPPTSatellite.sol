// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPPTSatellite
/// @notice Satellite entry point interface for cross-chain PPT operations
/// @dev Deployed on remote chains (Ethereum, Arbitrum, Base, etc.) to enable local interactions
interface IPPTSatellite {
    // ========== Enums ==========

    /// @notice Withdrawal mode options
    enum WithdrawMode {
        CrossChain,     // Standard cross-chain withdrawal (slower, no fee)
        Instant         // Instant local withdrawal (uses liquidity pool, may have fee)
    }

    // ========== Structs ==========

    /// @notice Cross-chain deposit parameters
    struct DepositParams {
        uint256 assets;         // Amount of assets to deposit
        address receiver;       // Address to receive shares
        uint256 minShares;      // Minimum shares to receive (slippage protection)
    }

    /// @notice Cross-chain withdrawal parameters
    struct WithdrawParams {
        uint256 shares;         // Amount of shares to withdraw
        address receiver;       // Address to receive assets
        uint256 minAssets;      // Minimum assets to receive (slippage protection)
        WithdrawMode mode;      // Withdrawal mode
    }

    // ========== Events ==========

    /// @notice Emitted when a cross-chain deposit is initiated
    /// @param user Address of the depositor
    /// @param assets Amount of assets deposited
    /// @param shares Shares minted (on Hub, received via OFT)
    /// @param nonce Cross-chain message nonce
    event CrossChainDeposit(
        address indexed user,
        uint256 assets,
        uint256 shares,
        uint64 nonce
    );

    /// @notice Emitted when a cross-chain withdrawal is initiated
    /// @param user Address of the withdrawer
    /// @param shares Amount of shares burned
    /// @param assets Assets to receive (on Hub)
    /// @param nonce Cross-chain message nonce
    event CrossChainWithdraw(
        address indexed user,
        uint256 shares,
        uint256 assets,
        uint64 nonce
    );

    /// @notice Emitted when an instant withdrawal is completed
    /// @param user Address of the withdrawer
    /// @param shares Amount of shares burned
    /// @param assets Assets received instantly
    /// @param fee Fee charged for instant withdrawal
    event InstantWithdraw(
        address indexed user,
        uint256 shares,
        uint256 assets,
        uint256 fee
    );

    // ========== View Functions ==========

    /// @notice Get the PPTOFT (OFT representation of PPT shares) address
    /// @return Address of the PPTOFT contract
    function pptOft() external view returns (address);

    /// @notice Get the liquidity pool address
    /// @return Address of the LiquidityPool contract
    function liquidityPool() external view returns (address);

    /// @notice Get the Hub chain endpoint ID
    /// @return LayerZero endpoint ID of the Hub (BSC)
    function hubEid() external view returns (uint32);

    /// @notice Get the underlying asset address
    /// @return Address of the underlying asset (e.g., USDT)
    function asset() external view returns (address);

    /// @notice Preview deposit - estimate shares to receive
    /// @param assets Amount of assets to deposit
    /// @return shares Estimated shares to receive
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview withdrawal - estimate assets to receive
    /// @param shares Amount of shares to withdraw
    /// @return assets Estimated assets to receive
    function previewWithdraw(uint256 shares) external view returns (uint256 assets);

    /// @notice Check if instant withdrawal is available
    /// @param shares Amount of shares to withdraw
    /// @return available True if instant withdrawal is possible
    /// @return assets Estimated assets to receive
    /// @return fee Fee for instant withdrawal
    function previewInstantWithdraw(uint256 shares) external view returns (
        bool available,
        uint256 assets,
        uint256 fee
    );

    // ========== User Actions ==========

    /// @notice Deposit assets and receive PPT shares via cross-chain
    /// @dev Assets are bridged to Hub before shares are minted.
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive shares
    /// @return shares Amount of shares to be received
    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares);

    /// @notice Deposit with explicit parameters
    /// @param params Deposit parameters
    /// @return shares Amount of shares to be received
    function depositWithParams(DepositParams calldata params) external payable returns (uint256 shares);

    /// @notice Withdraw shares for assets via cross-chain
    /// @dev Shares burned via OFT, assets released from Hub and sent cross-chain
    /// @param shares Amount of shares to burn
    /// @param receiver Address to receive assets
    /// @return assets Amount of assets to be received
    function withdraw(uint256 shares, address receiver) external payable returns (uint256 assets);

    /// @notice Withdraw with explicit parameters and mode selection
    /// @param params Withdrawal parameters including mode
    /// @return assets Amount of assets received
    function withdrawWithParams(WithdrawParams calldata params) external payable returns (uint256 assets);

    /// @notice Instant withdrawal using local liquidity pool
    /// @dev Uses credit-backed liquidity pool, may charge fee
    /// @param shares Amount of shares to burn
    /// @param receiver Address to receive assets
    /// @return assets Amount of assets received (after fee)
    function instantWithdraw(uint256 shares, address receiver) external returns (uint256 assets);

    // ========== Fee Quoting ==========

    /// @notice Quote LayerZero fee for deposit
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive shares
    /// @return nativeFee Native token fee required
    /// @return lzTokenFee LayerZero token fee (if applicable)
    function quoteDeposit(uint256 assets, address receiver) external view returns (uint256 nativeFee, uint256 lzTokenFee);

    /// @notice Quote LayerZero fee for cross-chain withdrawal
    /// @param shares Amount of shares to withdraw
    /// @param receiver Address to receive assets
    /// @return nativeFee Native token fee required
    /// @return lzTokenFee LayerZero token fee (if applicable)
    function quoteWithdraw(uint256 shares, address receiver) external view returns (uint256 nativeFee, uint256 lzTokenFee);

    // ========== Configuration ==========

    /// @notice Set instant withdrawal fee
    /// @param _feeBps Fee in basis points
    function setInstantWithdrawFee(uint256 _feeBps) external;

    /// @notice Pause/unpause the satellite
    /// @param paused True to pause, false to unpause
    function setPaused(bool paused) external;
}
