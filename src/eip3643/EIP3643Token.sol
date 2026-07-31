// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title EIP3643Token - EIP-3643 Security Token (UUPS Upgradeable)
/// @notice Regulated token with KYC checks, freezing, and pause functionality
/// @dev Core rules:
///   - All transfer/transferFrom check receiver's KYC status
///   - Agent can perform mint/burn/freeze/forcedTransfer operations
///   - ADMIN_ROLE can set Agent and switch KYC provider
///   - Supports partial freeze (freezePartialTokens): freeze part of user's tokens without affecting the rest
contract EIP3643Token is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    /// @notice Token name
    string public name;
    /// @notice Token symbol
    string public symbol;
    /// @notice Token decimals, fixed at 18
    uint8 public constant decimals = 18;
    /// @notice Total supply
    uint256 public totalSupply;

    /// @notice KYC provider (can be KYCAggregator with multiple providers, or a single provider)
    IIdentityRegistry public kycProvider;

    /// @notice Whether the contract is paused; all transfers are blocked when paused
    bool public paused;

    /// @dev User balances
    mapping(address => uint256) private _balances;
    /// @dev Allowances
    mapping(address => mapping(address => uint256)) private _allowances;
    /// @dev Whether an address is fully frozen (cannot send or receive)
    mapping(address => bool) private _frozen;
    /// @dev Amount of partially frozen tokens per address (these tokens cannot be transferred out)
    mapping(address => uint256) private _frozenTokens;

    // ============ Events ============

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    /// @notice Emitted when contract is paused
    event Paused(address indexed agent);
    /// @notice Emitted when contract is unpaused
    event Unpaused(address indexed agent);
    /// @notice Emitted when an address is frozen/unfrozen
    event AddressFrozen(address indexed userAddress, bool isFrozen, address indexed agent);
    /// @notice Emitted when tokens are partially frozen
    event TokensFrozen(address indexed userAddress, uint256 amount);
    /// @notice Emitted when tokens are partially unfrozen
    event TokensUnfrozen(address indexed userAddress, uint256 amount);
    /// @notice Emitted when KYC provider is changed
    event KYCProviderSet(address indexed kycProvider);

    // ============ Modifiers ============

    /// @notice Requires contract is not paused
    modifier whenNotPaused() {
        require(!paused, "Token is paused");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize function (replaces constructor)
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _kycProvider KYC provider address (KYCAggregator or single provider)
    /// @param admin Admin address
    /// @param upgrader Upgrader address
    function initialize(
        string memory _name,
        string memory _symbol,
        address _kycProvider,
        address admin,
        address upgrader
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, upgrader);
        name = _name;
        symbol = _symbol;
        kycProvider = IIdentityRegistry(_kycProvider);
    }

    // ============ ERC-20 Standard Interface ============

    /// @notice Query account balance
    /// @param account Address to query
    /// @return Token balance of the address
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /// @notice Query allowance
    /// @param _owner Token owner
    /// @param spender Approved spender
    /// @return Remaining allowance
    function allowance(address _owner, address spender) public view returns (uint256) {
        return _allowances[_owner][spender];
    }

    /// @notice Approve spender to spend tokens
    /// @param spender Address to approve
    /// @param amount Allowance amount
    /// @return Success
    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer (receiver must pass KYC, sender and receiver must not be frozen)
    /// @param to Receiver address
    /// @param amount Transfer amount
    /// @return Success
    function transfer(address to, uint256 amount) external whenNotPaused returns (bool) {
        _requireTransferCompliance(msg.sender, to, amount);
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer from (also requires KYC and freeze checks)
    /// @param from Sender address
    /// @param to Receiver address
    /// @param amount Transfer amount
    /// @return Success
    function transferFrom(address from, address to, uint256 amount) external whenNotPaused returns (bool) {
        require(_allowances[from][msg.sender] >= amount, "Insufficient allowance");
        _requireTransferCompliance(from, to, amount);
        _allowances[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    // ============ EIP-3643 Extended Functions ============

    /// @notice Check if an address is fully frozen
    /// @param userAddress Address to check
    /// @return Whether the address is frozen
    function isFrozen(address userAddress) external view returns (bool) {
        return _frozen[userAddress];
    }

    /// @notice Query the amount of partially frozen tokens for an address
    /// @param userAddress Address to query
    /// @return Amount of frozen tokens
    function getFrozenTokens(address userAddress) external view returns (uint256) {
        return _frozenTokens[userAddress];
    }

    /// @notice Change KYC provider (admin only), for switching between KYC aggregators or single providers
    /// @param _kycProvider New KYC provider address
    function setKYCProvider(address _kycProvider) external onlyRole(ADMIN_ROLE) {
        kycProvider = IIdentityRegistry(_kycProvider);
        emit KYCProviderSet(_kycProvider);
    }

    /// @notice Pause the contract, all transfers will be blocked (Agent only)
    function pause() external onlyRole(AGENT_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the contract (Agent only)
    function unpause() external onlyRole(AGENT_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Fully freeze/unfreeze an address (Agent only)
    /// @param userAddress Target address
    /// @param freeze true=freeze, false=unfreeze
    function setAddressFrozen(address userAddress, bool freeze) external onlyRole(AGENT_ROLE) {
        _frozen[userAddress] = freeze;
        emit AddressFrozen(userAddress, freeze, msg.sender);
    }

    /// @notice Partially freeze tokens (Agent only), frozen tokens cannot be transferred out
    /// @param userAddress Target address
    /// @param amount Amount of tokens to freeze
    function freezePartialTokens(address userAddress, uint256 amount) external onlyRole(AGENT_ROLE) {
        require(amount <= _balances[userAddress] - _frozenTokens[userAddress], "Amount exceeds available");
        _frozenTokens[userAddress] += amount;
        emit TokensFrozen(userAddress, amount);
    }

    /// @notice Unfreeze partial tokens (Agent only)
    /// @param userAddress Target address
    /// @param amount Amount of tokens to unfreeze
    function unfreezePartialTokens(address userAddress, uint256 amount) external onlyRole(AGENT_ROLE) {
        require(amount <= _frozenTokens[userAddress], "Amount exceeds frozen");
        _frozenTokens[userAddress] -= amount;
        emit TokensUnfrozen(userAddress, amount);
    }

    /// @notice Mint tokens (Agent only), receiver must pass KYC
    /// @param to Receiver address
    /// @param amount Mint amount
    function mint(address to, uint256 amount) external onlyRole(AGENT_ROLE) {
        require(kycProvider.isVerified(to), "Receiver not verified");
        _balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn tokens (Agent only)
    /// @param userAddress Address whose tokens are burned
    /// @param amount Burn amount
    /// @dev If burn amount exceeds available balance (total - frozen), frozen tokens are reduced accordingly
    function burn(address userAddress, uint256 amount) external onlyRole(AGENT_ROLE) {
        require(_balances[userAddress] >= amount, "Insufficient balance");
        if (_frozenTokens[userAddress] > 0) {
            if (amount > _balances[userAddress] - _frozenTokens[userAddress]) {
                _frozenTokens[userAddress] -= (amount - (_balances[userAddress] - _frozenTokens[userAddress]));
            }
        }
        _balances[userAddress] -= amount;
        totalSupply -= amount;
        emit Transfer(userAddress, address(0), amount);
    }

    /// @notice Forced transfer (Agent only), skips freeze checks but still requires receiver KYC
    /// @param from Sender address
    /// @param to Receiver address
    /// @param amount Transfer amount
    /// @return Success
    /// @dev Used for regulatory enforcement, e.g. court-ordered asset transfers
    function forcedTransfer(address from, address to, uint256 amount) external onlyRole(AGENT_ROLE) returns (bool) {
        require(kycProvider.isVerified(to), "Receiver not verified");
        require(_balances[from] >= amount, "Insufficient balance");
        if (_frozenTokens[from] > 0) {
            if (amount > _balances[from] - _frozenTokens[from]) {
                _frozenTokens[from] -= (amount - (_balances[from] - _frozenTokens[from]));
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Wallet recovery (Agent only), transfers all assets from lost wallet to new wallet
    /// @param lostWallet Lost wallet address (will be frozen after transfer)
    /// @param newWallet New wallet address (must pass KYC)
    /// @return Success
    /// @dev Lost wallet is automatically frozen after transfer to prevent further use
    function recoveryAddress(address lostWallet, address newWallet) external onlyRole(AGENT_ROLE) returns (bool) {
        require(kycProvider.isVerified(newWallet), "New wallet not verified");
        uint256 balance = _balances[lostWallet];
        _balances[newWallet] += balance;
        _balances[lostWallet] = 0;
        _frozen[lostWallet] = true;
        if (_frozenTokens[lostWallet] > 0) {
            _frozenTokens[newWallet] = _frozenTokens[lostWallet];
            _frozenTokens[lostWallet] = 0;
        }
        emit Transfer(lostWallet, newWallet, balance);
        return true;
    }

    // ============ Internal Functions ============

    /// @dev Internal transfer logic
    function _transfer(address from, address to, uint256 amount) internal {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    /// @dev Transfer compliance check: sender/receiver must not be frozen, sufficient available balance, receiver must pass KYC
    function _requireTransferCompliance(address from, address to, uint256 amount) internal view {
        require(!_frozen[from], "Sender is frozen");
        require(!_frozen[to], "Receiver is frozen");
        require(amount <= _balances[from] - _frozenTokens[from], "Insufficient available balance");
        require(kycProvider.isVerified(to), "Receiver not verified");
    }

    /// @dev UUPS upgrade authorization check (upgrader only)
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
