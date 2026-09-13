// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title ShadowERC20 - Shadow ERC-20 token for EIP-3643 (UUPS upgradeable)
/// @notice Plain ERC-20 mapped 1:10 against the underlying EIP-3643 security token
/// @dev Core rules:
///   - Free transfers: anyone can move tokens without KYC restrictions
///   - No independent minting: only the Bridge contract can call mint/burn
///   - Total supply always equals the EIP-3643 locked in Bridge * 10
contract ShadowERC20 is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Token name
    string public name;
    /// @notice Token symbol
    string public symbol;
    /// @notice Token decimals, fixed at 18
    uint8 public constant decimals = 18;
    /// @notice Total supply (changes dynamically with Bridge mint/burn)
    uint256 public totalSupply;

    /// @notice Bridge contract address, the only entity allowed to mint/burn
    address public bridge;

    /// @dev User balances
    mapping(address => uint256) private _balances;
    /// @dev Allowances
    mapping(address => mapping(address => uint256)) private _allowances;

    // ===== V2 storage, appended for the xSPCX x1/20 reverse split (slots 0-5 untouched) =====

    /// @notice When true, transfer/transferFrom/mint/burn are blocked
    bool public paused;
    /// @notice When true, migrateBalances is permanently locked
    bool public migrationFinalized;
    /// @notice Per-holder migration marker, prevents double scaling
    mapping(address => bool) public migrated;

    /// @notice Reverse split ratio: every 20 old tokens become 1 new token
    uint256 public constant SPLIT_NUMERATOR = 1;
    uint256 public constant SPLIT_DENOMINATOR = 20;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    /// @notice Emitted when the Bridge address is updated
    event BridgeSet(address indexed bridge);
    /// @notice Emitted when pause state changes
    event PausedSet(bool paused);
    /// @notice Emitted per holder migrated in the reverse split
    event BalanceMigrated(address indexed holder, uint256 oldBalance, uint256 newBalance);
    /// @notice Emitted when the migration is permanently finalized
    event MigrationFinalized(uint256 finalTotalSupply);

    /// @notice Restricts call to the Bridge contract
    modifier onlyBridge() {
        require(msg.sender == bridge, "Only bridge");
        _;
    }

    /// @notice Blocks token movement while paused
    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer (replaces constructor)
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param admin Admin address (multisig)
    /// @param upgrader Upgrade authority address (timelock)
    function initialize(string memory _name, string memory _symbol, address admin, address upgrader) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, upgrader);
        name = _name;
        symbol = _symbol;
    }

    // ============ xSPCX x1/20 reverse split (one-time migration) ============

    /// @notice V2 initializer - pauses the token in the same tx as the upgrade
    /// @dev Call via upgradeToAndCall so there is no upgrade->pause window to front-run.
    ///      Effect is hardcoded (paused = true), so an unexpected external caller could
    ///      only set the exact state the upgrade intends.
    function initializeV2() external reinitializer(2) {
        paused = true;
        emit PausedSet(true);
    }

    /// @notice Rewrite holder balances x1/20 (multiply first, then floor-divide)
    /// @param holders Holder addresses to migrate (duplicates and zero balances are skipped)
    /// @dev Emits Transfer(holder, 0x0, delta) so explorers/wallets/indexers stay consistent.
    ///      old <= 1.5e23 (150k supply); SPLIT_NUMERATOR=1 so no multiply overflow.
    function migrateBalances(address[] calldata holders) external onlyRole(ADMIN_ROLE) {
        require(paused, "Not paused");
        require(!migrationFinalized, "Migration finalized");
        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            if (migrated[h]) continue; // double-scaling guard
            migrated[h] = true;
            uint256 oldBal = _balances[h];
            if (oldBal == 0) continue;
            uint256 newBal = oldBal * SPLIT_NUMERATOR / SPLIT_DENOMINATOR;
            _balances[h] = newBal;
            totalSupply -= (oldBal - newBal);
            emit Transfer(h, address(0), oldBal - newBal);
            emit BalanceMigrated(h, oldBal, newBal);
        }
    }

    /// @notice Permanently lock the migration path (irreversible)
    function finalizeMigration() external onlyRole(ADMIN_ROLE) {
        require(!migrationFinalized, "Already finalized");
        migrationFinalized = true;
        emit MigrationFinalized(totalSupply);
    }

    /// @notice Pause / unpause token movement (admin only)
    function setPaused(bool _paused) external onlyRole(ADMIN_ROLE) {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Set the Bridge contract address (admin only)
    /// @param _bridge Bridge contract address
    /// @dev Only the Bridge can mint/burn, which prevents independent issuance of ERC-20 supply
    function setBridge(address _bridge) external onlyRole(ADMIN_ROLE) {
        require(_bridge != address(0), "Invalid bridge");
        bridge = _bridge;
        emit BridgeSet(_bridge);
    }

    // ============ ERC-20 standard interface (free transfers, no KYC) ============

    /// @notice Read the balance of an account
    /// @param account Target address
    /// @return Amount of tokens held by the account
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /// @notice Read the remaining allowance
    /// @param _owner Owner of the tokens
    /// @param spender Authorized spender
    /// @return Remaining allowance
    function allowance(address _owner, address spender) public view returns (uint256) {
        return _allowances[_owner][spender];
    }

    /// @notice Approve spender for a given amount
    /// @param spender Authorized address
    /// @param amount Allowance amount
    /// @return Success flag
    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer tokens (free, no KYC checks)
    /// @param to Recipient
    /// @param amount Amount to transfer
    /// @return Success flag
    function transfer(address to, uint256 amount) external whenNotPaused returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer tokens via allowance (free, no KYC checks)
    /// @param from Sender
    /// @param to Recipient
    /// @param amount Amount to transfer
    /// @return Success flag
    function transferFrom(address from, address to, uint256 amount) external whenNotPaused returns (bool) {
        require(_allowances[from][msg.sender] >= amount, "Insufficient allowance");
        _allowances[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    // ============ Bridge-only interface ============

    /// @notice Mint shadow tokens (Bridge only)
    /// @param to Recipient
    /// @param amount Amount to mint
    /// @dev Called when EIP-3643 tokens are deposited into the Bridge, minted at 1:10 ratio
    function mint(address to, uint256 amount) external onlyBridge whenNotPaused {
        _balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn shadow tokens (Bridge only)
    /// @param from Holder whose tokens are burned
    /// @param amount Amount to burn
    /// @dev Called when a user redeems ERC-20 back to EIP-3643: ERC-20 is burned, 3643 is released from Bridge
    function burn(address from, uint256 amount) external onlyBridge whenNotPaused {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ============ Internal functions ============

    /// @dev Internal transfer logic
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "Transfer from zero");
        require(to != address(0), "Transfer to zero");
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    /// @dev UUPS upgrade authorization (timelock only)
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
