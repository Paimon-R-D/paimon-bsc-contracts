// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// Self-contained Pre-IPO Token. Deploy ONLY the PreIPOToken contract. No Token proxy.
// Repository: https://git.toolsfdg.net/william-lll/capped-token-template
// Branch: feat/preipo-token; commit: b8062e57de0bd6d51fc0dfd8a3f1e5e40bd2769b
// Build: Solidity 0.8.35; optimizer ON, 200 runs; EVM Cancun; viaIR OFF.
// OpenZeppelin Contracts 5.5.0, commit fcbae5394ae8ad52d8e580a3477db99814b9d565.
// Source/license comments retained; imports inlined; Solidity pragma pinned to the repository compiler.
// SafeIntrospection is internal: no separate library deployment or linking is needed.
// Three existing, correctly configured Safe wallets are required as constructor parameters.

/*
The MIT License (MIT)

Copyright (c) 2016-2025 Zeppelin Group Ltd

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

// ============================================================================
// File: lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol
// Source SHA-256: 01b6f5c4fa45fd38822b286ecef6daf983d27306dd6362496fa71b3e4600b72c
// ============================================================================

// Original source license: MIT
// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)



/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// ============================================================================
// File: lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol
// Source SHA-256: 0b7132f17d14d1d84b41b0bb429be62dafdff00fd3470f68724d8018eb07f57a
// ============================================================================

// Original source license: MIT
// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/extensions/IERC20Metadata.sol)





/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// ============================================================================
// File: lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/Context.sol
// Source SHA-256: 847fda5460fee70f56f4200f59b82ae622bb03c79c77e67af010e31b7e2cc5b6
// ============================================================================

// Original source license: MIT
// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)



/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// ============================================================================
// File: lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol
// Source SHA-256: fa7068f56bc180571a6095be6eaef06d51dbe81e30cb128397d993c9599ecc30
// ============================================================================

// Original source license: MIT
// OpenZeppelin Contracts (last updated v5.5.0) (interfaces/draft-IERC6093.sol)



/**
 * @dev Standard ERC-20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC-721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in ERC-721.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC-1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}

// ============================================================================
// File: lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol
// Source SHA-256: 50f34ae16a067a41c2c1091445d11d63788e54c717677cb6d6b0e4cdea2ad21d
// ============================================================================

// Original source license: MIT
// OpenZeppelin Contracts (last updated v5.5.0) (token/ERC20/ERC20.sol)








/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC-20
 * applications.
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * Both values are immutable: they can only be set once during construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /// @inheritdoc IERC20
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Skips emitting an {Approval} event indicating an allowance update. This is not
     * required by the ERC. See {xref-ERC20-_approve-address-address-uint256-bool-}[_approve].
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner`'s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation sets the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the `transferFrom` operation can force the flag to
     * true using the following override:
     *
     * ```solidity
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}

// ============================================================================
// File: lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/Pausable.sol
// Source SHA-256: 2c26130748f06552c65ca74d89eaf78c9324a3cbac3ba6fdbadaa8beba0cb0b4
// ============================================================================

// Original source license: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/Pausable.sol)





/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context {
    bool private _paused;

    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    /**
     * @dev The operation failed because the contract is paused.
     */
    error EnforcedPause();

    /**
     * @dev The operation failed because the contract is not paused.
     */
    error ExpectedPause();

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        _requirePaused();
        _;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Throws if the contract is paused.
     */
    function _requireNotPaused() internal view virtual {
        if (paused()) {
            revert EnforcedPause();
        }
    }

    /**
     * @dev Throws if the contract is not paused.
     */
    function _requirePaused() internal view virtual {
        if (!paused()) {
            revert ExpectedPause();
        }
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}

// ============================================================================
// File: src/SafeIntrospection.sol
// Source SHA-256: 6fc4fc7dfd8e3b80e07ff1f7bdad49570ae332d5f1d5ac23fe80a3905f105ff3
// ============================================================================

// Original source license: MIT
/// @dev The subset of the Safe (formerly Gnosis Safe) surface this template reads. Declared locally
/// rather than pulled in as a dependency: five view functions do not justify a submodule, and a Safe
/// release that changed any of these signatures would be a deliberate re-audit rather than something
/// to inherit silently.
interface IGnosisSafe {
    function VERSION() external view returns (string memory);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory);
}

/// @notice Admission checks for the Safes this template hands authority to.
///
/// These checks establish *shape*, never authenticity. Nothing here proves the address is a real Safe
/// rather than a contract that answers the same five view functions with whatever it likes — and a
/// contract like that is controlled by whoever wrote it no matter what `getOwners()` claims, so
/// tightening the claims it returns (rejecting duplicate owners, say) buys nothing against it. A
/// genuine Safe cannot hold duplicate owners in the first place. The control for a forged Safe is the
/// operator choosing the addresses, plus the delays and the public event trail; it is not here.
///
/// Every check here is a snapshot of the instant it runs. A Safe can add an owner, lower its
/// threshold, or enable a module the block after it was accepted, and nothing on-chain will notice.
/// Comparing addresses also cannot establish that two signer sets belong to organizationally
/// independent people. These are limits of the approach, not gaps to be closed by adding checks —
/// the delays and the public event trail are what cover the window afterwards.
library SafeIntrospection {
    /// @dev The design's floor, not an exact shape: a stricter Safe (4 owners, threshold 3) passes.
    uint256 internal constant MIN_OWNERS = 3;
    uint256 internal constant MIN_THRESHOLD = 2;

    /// @dev Safe's module list is a linked list whose head and tail are both this address.
    address private constant SENTINEL_MODULES = address(0x1);

    /// @dev keccak256("fallback_manager.handler.address"). Safe keeps the handler outside its declared
    /// storage layout and exposes no getter for it, so the only way to read it is by slot.
    ///
    /// `internal` so the deploy script's diagnostic reads the same constant this does. The test mock
    /// deliberately keeps its own copy instead: it plays the part of a real Safe, so an independent
    /// literal there is a cross-check on this one rather than a duplicate of it.
    bytes32 internal constant FALLBACK_HANDLER_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

    error SafeHasNoCode(address safe);
    error SafeVersionUnavailable(address safe);
    error SafeProbeFailed(address safe, bytes4 probe);
    error SafeOwnerCountTooLow(address safe, uint256 ownerCount);
    error SafeThresholdTooLow(address safe, uint256 threshold);
    error SafeHasModule(address safe, address module);
    error SafeHasFallbackHandler(address safe, address handler);
    error SafeSignersOverlap(address first, address second, address sharedSigner);

    /// @notice Rejects anything that is not a Safe holding at least `MIN_OWNERS` owners at a threshold
    /// of at least `MIN_THRESHOLD`, with no path that could act on fewer signatures than that.
    /// @return safeOwners The owner list this had to fetch anyway. Returned so a caller that goes on
    /// to compare against it does not pay for the same fetch again; callers that do not need it just
    /// ignore the value.
    /// @dev No upper bound on what the probes below may return, and none is wanted. A forged Safe can
    /// answer `getOwners()` with a huge array and make the proposal expensive, but nothing here is
    /// permissionless: reaching this code takes the proposing role, against an address that role
    /// chose. It is a gun pointed at its owner's foot, and the whole contract already assumes the
    /// seats do not want to brick themselves.
    ///
    /// A length cap would also not stop the cost it is aimed at. Solidity decodes the return data into
    /// memory before any statement of ours runs, so the memory expansion is already paid by the time a
    /// bound could be tested. Avoiding it means hand-rolled `staticcall`s with fixed return buffers
    /// and manual ABI decoding — an assembly re-implementation of five probes, in the one file whose
    /// job is to be readable enough to audit, to blunt a self-inflicted gas bill.
    function requireApprovedSafe(address safe) internal view returns (address[] memory safeOwners) {
        if (safe.code.length == 0) revert SafeHasNoCode(safe);

        // VERSION() doubles as the shape probe: something that answers it with a non-empty string is
        // Safe-shaped, and the try/catch turns "answers no such selector" into a legible error rather
        // than a bare revert at deployment time.
        //
        // Deliberately NOT a version whitelist. This contract can never be upgraded, so pinning an
        // allowed set would turn a future Safe release into a permanent inability to rotate a role or
        // the inventory Safe — and it would add little on top of the behavioural checks below, which
        // are what actually bound the Safe's authority.
        try IGnosisSafe(safe).VERSION() returns (string memory version) {
            if (bytes(version).length == 0) revert SafeVersionUnavailable(safe);
        } catch {
            revert SafeVersionUnavailable(safe);
        }

        // Every probe below is wrapped as well. Answering `VERSION()` establishes Safe-shaped, not
        // Safe-complete: `getModulesPaginated` only arrived in a later release, so a genuinely old
        // Safe answers the version and then stops. Rejecting it is right — a module list this cannot
        // read is a module list this cannot clear — but it has to reject it with a reason, and a bare
        // revert with no data is the exact failure the version try/catch was added to avoid.
        //
        // `SafeProbeFailed` carries the selector rather than there being four separate errors: the
        // question an operator has is which probe the address stopped answering, and one error with
        // that in it says so without four near-identical declarations.
        //
        // Note the reverts inside the success blocks: a `catch` only catches the external call
        // failing, never the block that runs after it succeeded, so `SafeHasModule` and
        // `SafeHasFallbackHandler` still propagate as themselves.
        uint256 ownerCount;
        try IGnosisSafe(safe).getOwners() returns (address[] memory owners) {
            safeOwners = owners;
            ownerCount = owners.length;
        } catch {
            revert SafeProbeFailed(safe, IGnosisSafe.getOwners.selector);
        }
        if (ownerCount < MIN_OWNERS) revert SafeOwnerCountTooLow(safe, ownerCount);

        uint256 threshold;
        try IGnosisSafe(safe).getThreshold() returns (uint256 value) {
            threshold = value;
        } catch {
            revert SafeProbeFailed(safe, IGnosisSafe.getThreshold.selector);
        }
        if (threshold < MIN_THRESHOLD) revert SafeThresholdTooLow(safe, threshold);

        // A page size of one is enough because the requirement is that the list be empty, not that it
        // be enumerated: one entry coming back is already a rejection, and the cursor is never read.
        try IGnosisSafe(safe).getModulesPaginated(SENTINEL_MODULES, 1) returns (address[] memory modules, address) {
            if (modules.length != 0) revert SafeHasModule(safe, modules[0]);
        } catch {
            revert SafeProbeFailed(safe, IGnosisSafe.getModulesPaginated.selector);
        }

        // A fallback handler receives every call whose selector the Safe does not implement, and the
        // Safe forwards it with the caller's address appended.
        //
        // What it is NOT: a way to act as the Safe. `FallbackManager` forwards with `CALL`, not
        // `DELEGATECALL`, so the handler runs in its own context and can neither touch the Safe's
        // storage nor make the Safe execute anything — a call back in arrives from the handler's own
        // address, which is not an owner. Disassembling the four singletons deployed on BNB Smart
        // Chain (Safe and SafeL2, 1.3.0 and 1.4.1) puts a plain `CALL` after the handler `SLOAD` in
        // every one. An earlier version of this comment claimed the handler was "a second execution
        // path into the Safe's context"; that was simply wrong, and the check does not rest on it.
        //
        // What it is: the ability to make the Safe's *address* answer arbitrary selectors with
        // arbitrary data. Nothing this library probes can be intercepted that way, because a genuine
        // Safe implements all five natively. The exposure is elsewhere — EIP-1271 `isValidSignature`,
        // which a handler can answer however it likes, so any protocol that accepts the Safe's
        // signature off-chain is trusting the handler. This Token never asks: authority here is
        // `msg.sender == theSafe`, which needs a real `execTransaction` carrying the threshold.
        //
        // OPEN, and the reason this comment is long: the check therefore costs more than it defends.
        // Requiring a zero handler rejects the official `CompatibilityFallbackHandler`, which the Safe
        // web UI installs on every Safe it creates — 28 of 38 consecutive production Safes surveyed on
        // BNB Smart Chain carry one, and only 4 clear all four checks here. Operators must create the
        // seats without a handler or clear it with `setFallbackHandler(0)` first. Kept as-is until the
        // business decides, because loosening an admission check is not a refactor;
        // `PreIPOTokenBscFork.t.sol` pins the consequence against real Safes either way.
        //
        // The transaction guard at keccak256("guard_manager.guard.address") is deliberately NOT
        // checked, even though it lives in the same undeclared-storage corner and reads the same way.
        // A guard can only refuse transactions that already carry the threshold, never approve one
        // that does not, so guards are a hardening tool (spend limits, allowlists) and requiring their
        // absence would reject the stricter configuration. A guard that bricks its own Safe is that
        // Safe's governance problem, it can be installed the block after any check here, and a seat
        // that cannot act is already the recovery boundary the design documents.
        try IGnosisSafe(safe).getStorageAt(uint256(FALLBACK_HANDLER_SLOT), 1) returns (bytes memory raw) {
            // A well-formed `bytes` that is nevertheless too short would panic in `abi.decode`, which
            // would be another reasonless revert.
            if (raw.length < 32) revert SafeProbeFailed(safe, IGnosisSafe.getStorageAt.selector);
            address handler = address(uint160(uint256(abi.decode(raw, (bytes32)))));
            if (handler != address(0)) revert SafeHasFallbackHandler(safe, handler);
        } catch {
            revert SafeProbeFailed(safe, IGnosisSafe.getStorageAt.selector);
        }
    }

    /// @notice Admits `candidate` and rejects it if its signers overlap either named address.
    /// @dev The composite exists to pay for `candidate.getOwners()` once. Spelled out as three
    /// separate calls it was fetched three times — admission plus once per comparison — which measured
    /// 5.8k wasted gas at the three-owner floor and 46.6k against a 50-owner candidate, on a
    /// state-changing transaction rather than a read.
    ///
    /// Which two addresses a candidate is held against stays with the caller: that is the Token's
    /// policy about seats, not a fact about Safes, and this only mechanises the comparison.
    function requireApprovedAndDisjoint(address candidate, address first, address second) internal view {
        address[] memory candidateOwners = requireApprovedSafe(candidate);
        _requireDisjointFrom(first, candidate, candidateOwners);
        _requireDisjointFrom(second, candidate, candidateOwners);
    }

    /// @notice Rejects two Safes that share any signer. Fetches both lists; prefer
    /// `requireApprovedAndDisjoint` when the same candidate is compared more than once.
    function requireDisjointSigners(address first, address second) internal view {
        _requireDisjointFrom(first, second, IGnosisSafe(second).getOwners());
    }

    /// @notice The complete rule for a fresh set of three seats: each admissible on its own, and no
    /// two sharing a signer.
    /// @dev Exists so the deploy script's verdict can run *exactly* what the constructor runs. The
    /// script previously probed the three Safes one at a time and printed "would be accepted" for
    /// each, which is true and yet says nothing about the rule most likely to stop a real deployment:
    /// three Safes staffed by one set of people each pass individually and the constructor still
    /// reverts. Any function the script wrote itself to cover that would be a second implementation of
    /// the rule, which is how the per-probe diagnostics have already drifted twice.
    ///
    /// Nine `getOwners()` fetches where three would do, and left that way on purpose: deduplicating
    /// would mean threading three local owner arrays through the pairwise comparisons, which is the one
    /// shape that lets a caller compare the wrong list. Deployment is a single transaction whose cost
    /// nobody pays twice — unlike the handover paths, where the same saving was worth taking, see
    /// `requireApprovedAndDisjoint`.
    ///
    /// Three-way, not just between the two governing roles. A signer who sits on the Owner Safe and on
    /// the Safe holding every issued Token concentrates propose-and-hold in one person, which the
    /// two-role split exists to prevent. Passing the same Safe twice is caught by this too: a set
    /// always overlaps itself.
    function requireApprovedTrio(address ownerSafe, address confirmerSafe, address inventorySafe) internal view {
        requireApprovedSafe(ownerSafe);
        requireApprovedSafe(confirmerSafe);
        requireApprovedSafe(inventorySafe);

        requireDisjointSigners(ownerSafe, confirmerSafe);
        requireDisjointSigners(ownerSafe, inventorySafe);
        requireDisjointSigners(confirmerSafe, inventorySafe);
    }

    /// @dev Quadratic, and `requireApprovedSafe` sets no ceiling on owner count. At the three-owner
    /// floor this is nine comparisons.
    ///
    /// Admission bounds the *candidate* and nothing else. An address that is already seated can grow
    /// its own owner set afterwards through its own Safe governance, which is entirely outside this
    /// contract's reach — so the honest bound is "however large the seats have since become", not
    /// anything fixed at admission. If a seat grows past what `getOwners()` can return inside a block,
    /// every rotation touching that seat becomes unaffordable, including the one meant to replace it.
    ///
    /// A ceiling here would not close it: the growth happens after the check, so refusing large
    /// candidates prevents nothing.
    ///
    /// What bounds the damage is which comparisons read which seat. The inventory seat is compared
    /// against in both role replacements, so bloating it makes those dearer — measured at 3.0k gas per
    /// extra owner, taking `proposeOwnerReplacement` from 197k against a three-owner seat to 791k
    /// against a 200-owner one, and needing on the order of ten thousand owners to reach a 30M block
    /// limit. But replacing the inventory seat itself compares the candidate against the Owner and
    /// Confirmer Safes and never reads the outgoing seat's owners, so the escape costs the same
    /// whatever that seat has become. Nothing else — quota, issuance, share ratio, unpause,
    /// settlement, closure, pause, veto, withdrawal — reads a seat's owner list at all.
    ///
    /// So the worst a bloated seat achieves is making role rotation expensive until it is itself
    /// rotated out, through a path it cannot make expensive.
    /// `test_ABloatedInventorySeatDoesNotBlockItsOwnReplacement` pins that.
    ///
    /// `holder` is the outer loop so the reported shared signer is the first one *it* declares, which
    /// keeps the error stable regardless of which side supplied the pre-fetched list.
    function _requireDisjointFrom(address holder, address candidate, address[] memory candidateOwners) private view {
        address[] memory holderOwners = IGnosisSafe(holder).getOwners();

        for (uint256 i = 0; i < holderOwners.length; i++) {
            for (uint256 j = 0; j < candidateOwners.length; j++) {
                if (holderOwners[i] == candidateOwners[j]) {
                    revert SafeSignersOverlap(holder, candidate, holderOwners[i]);
                }
            }
        }
    }
}

// ============================================================================
// File: src/PreIPOTokenTypes.sol
// Source SHA-256: 54f302e88c2e02be23956f287c19b0e859f5ad0577fe768f7d87ae265f3dbfe8
// ============================================================================

// Original source license: MIT
/// Every governed action is one of these. Owner replacement and Confirmer replacement are separate
/// kinds rather than one kind carrying a "which role" field because the two flip proposer and
/// approver: the Confirmer proposes an Owner replacement and the Owner approves it, and vice versa.
/// Split, "who may propose this kind" is a pure function of the kind and cannot be wired up backwards.
enum RequestKind {
    IncreaseQuota,
    Issuance,
    ReplaceInventorySafe,
    ReplaceSettlementAddress,
    UpdateShareRatio,
    Unpause,
    ReplaceOwner,
    ReplaceConfirmer,
    CloseIssuance
}

/// `Proposed` means one role has signed; `Confirmed` means both have and the delay is running.
/// The three terminal states are distinguished rather than collapsed because the public record has to
/// answer *why* a request never took effect, not just that it didn't.
enum RequestStatus {
    None,
    Proposed,
    Confirmed,
    Executed,
    Cancelled,
    Expired
}

/// Slot 0 holds everything the lifecycle needs (30 of the 32 bytes: kind 1, status 1, readyAt 8,
/// expiresAt 8, and three 4-byte epochs), slot 1 the evidence hash. Two bytes spare — a fourth
/// epoch would spill into a second slot.
///
/// `expiresAt` is always `readyAt + EXECUTION_WINDOW` and is stored anyway. Not an oversight: both
/// fields sit in slot 0, so one SSTORE writes them together and dropping it would save nothing on the
/// write and nothing on the read. Deriving it would also make the value meaningless rather than absent
/// before confirmation — `readyAt` is zero then, so a derived deadline would come back as
/// `EXECUTION_WINDOW` instead of zero. Stored, the public record answers "when does this lapse"
/// directly, without the reader having to know the window length.
///
/// `readyAt` and `expiresAt` are zero until confirmation, which is what makes an unconfirmed request
/// non-expiring: the design gives no timeout on the proposal side, only on the confirmed side. The
/// proposing role can withdraw and the approving role can veto, so a stale proposal is never stuck.
///
/// The proposal and confirmation timestamps are deliberately not stored. `readyAt` minus the kind's
/// fixed delay is the confirmation instant, and both moments are in the event trail; a second copy in
/// storage would be one more thing that could disagree.
struct Request {
    RequestKind kind;
    RequestStatus status;
    uint64 readyAt;
    uint64 expiresAt;
    // Recorded for every kind, compared only for the two role replacements — at confirmation as well
    // as at acceptance, since a draft whose recorded generation has been passed is void beyond
    // recovery and approving it spends a signature on nothing. Two concurrent
    // confirmed Owner replacements would otherwise both stay acceptable: candidate A takes the role,
    // and candidate B — approved by the Owner that A displaced — can take it from A afterwards.
    // Checking the epochs kills every role-replacement draft the moment either role actually moves.
    //
    // Ordinary *delayed* requests are deliberately left alone by this. An incoming role already has a
    // remedy for drafts its predecessor left behind: it can withdraw or veto them during the window.
    // Failing them outright would turn "rotate a signer set" into "restart every proposal in flight",
    // which the design does not ask for.
    //
    // The exception is anything with no delay, where confirmation is the execution and that window
    // does not exist — the remedy becomes a race, so the generations are compared. Closure is the one
    // such kind, and leaving it out let a former Owner's abandoned proposal be applied irreversibly by
    // the Confirmer alone.
    uint32 ownerEpoch;
    uint32 confirmerEpoch;
    // Which halt this request was raised under, compared only for `Unpause` — at confirmation as well
    // as at execution, for the same reason as the role generations above. Two unpause
    // requests can be approved for one halt, so resolving it with one leaves the other confirmed and
    // still inside its window; without this, that leftover could undo a later incident with no fresh
    // deliberation at all. Bumping a counter on every pause invalidates all of them at once, which is
    // the same O(1) trick the inventory receiver and the closure flag use.
    uint32 pauseEpoch;
    bytes32 evidenceHash;
}

/// The receiver is fixed at proposal time, not resolved at execution time. That is the whole job of
/// this field: it is what stops the permissionless executor redirecting a mint.
///
/// It is deliberately *not* what invalidates an issuance drafted against a replaced inventory Safe —
/// that is the seat generation in `Request.expectedSeatEpoch`. Comparing the address looked like it
/// would do the same work, and did not: hand the seat away and take it back, and a draft written
/// before either move matches again, so a replacement used to stop a bad issuance was undone by any
/// later move back.
struct IssuanceTerms {
    uint256 amount;
    address inventorySafe;
}

/// A fraction, not a fixed-point scalar: the design's own table requires both "1 Token = 2 shares"
/// and "1 Token = 0.5 share", and repeated splits and reverse-splits must not accumulate rounding.
/// The contract never computes with this — it is a published record, and no balance, allowance, or
/// supply is derived from it.
struct ShareRatio {
    uint256 numerator;
    uint256 denominator;
}

// ============================================================================
// File: src/PreIPOToken.sol
// Source SHA-256: fa3db1f5d760d02b2714f5aabe265a5ca26f357e4981c590b6a8ad9389287fa1
//   ^^ STALE. This section was modified by Paimon (genesis mint); the hash above describes the
//      vendor's original and no longer matches the code below. See the banner at the top of the file.
// ============================================================================

// Original source license: MIT
contract PreIPOToken is ERC20, Pausable {
    // ---------------------------------------------------------------------------------------------
    // Waiting times
    // ---------------------------------------------------------------------------------------------

    uint64 public constant ISSUANCE_DELAY = 24 hours;
    uint64 public constant INVENTORY_DELAY = 24 hours;
    uint64 public constant UNPAUSE_DELAY = 24 hours;
    uint64 public constant QUOTA_DELAY = 72 hours;
    uint64 public constant SETTLEMENT_DELAY = 72 hours;
    uint64 public constant SHARE_RATIO_DELAY = 72 hours;
    uint64 public constant ROLE_CHANGE_DELAY = 72 hours;
    uint64 public constant EXECUTION_WINDOW = 7 days;

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    address public ownerSafe;
    address public confirmerSafe;
    address public inventorySafe;
    address public settlementAddress;

    uint32 public ownerEpoch;
    uint32 public confirmerEpoch;
    /// @notice Incremented by every `pause()`. Published so an off-chain observer can tell whether a
    /// confirmed unpause request still belongs to the halt currently in force.
    uint32 public pauseEpoch;
    /// @notice Incremented every time the corresponding seat is handed over. Published so an observer
    /// can tell whether a confirmed handover still belongs to the generation it was drafted against.
    uint32 public inventoryEpoch;
    uint32 public settlementEpoch;

    bool public issuanceClosed;

    uint256 public issuanceQuota;
    uint256 public sharesPerTokenNumerator;
    uint256 public sharesPerTokenDenominator;

    uint256 public nextRequestId;

    mapping(uint256 => Request) public requests;
    mapping(uint256 => uint256) public proposedQuota;
    mapping(uint256 => IssuanceTerms) public proposedIssuance;
    mapping(uint256 => address) public proposedAddress;
    /// @notice The seat generation a draft was written against: the two custody handovers, plus every
    /// issuance, which is drafted against a particular inventory seat. Read back at acceptance or
    /// execution so a superseded draft cannot take effect against a seat that has since changed hands.
    ///
    /// A generation and not the incumbent's address: the seat can be handed away and handed back, and
    /// an address comparison would wave a draft from before both moves straight through. Which
    /// counter it is compared against is decided by the request's kind.
    mapping(uint256 => uint32) public expectedSeatEpoch;
    mapping(uint256 => ShareRatio) public proposedShareRatio;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event Deployed(
        address indexed ownerSafe, address indexed confirmerSafe, address indexed inventorySafe, bytes32 evidenceHash
    );

    event RequestProposed(
        uint256 indexed requestId, RequestKind indexed kind, address indexed proposer, bytes32 evidenceHash
    );
    /// @dev `confirmedBy`, not `confirmer`: an Owner replacement is approved by the *Owner* Safe, since
    /// the design has the role being replaced approve its own replacement. Naming the field after the
    /// Confirmer role made an off-chain reader misattribute those approvals — the same mistake
    /// `RequestWithdrawn` carried. `RequestProposed.proposer` needs no such fix, being role-neutral,
    /// and `RequestVetoed.confirmer` is accurate because only the Confirmer may veto.
    event RequestConfirmed(uint256 indexed requestId, address indexed confirmedBy, uint64 readyAt, uint64 expiresAt);
    event RequestExecuted(uint256 indexed requestId, address indexed executor);
    event RequestAccepted(uint256 indexed requestId, address indexed acceptor);
    /// @dev `withdrawnBy`, not `proposer`: role replacement lets *either* participating role pull a
    /// draft, so for those kinds this can be the approving Safe rather than the one that proposed it.
    /// Naming it `proposer` made an off-chain reader misattribute the withdrawal.
    event RequestWithdrawn(uint256 indexed requestId, address indexed withdrawnBy);
    event RequestVetoed(uint256 indexed requestId, address indexed confirmer);
    event RequestExpired(uint256 indexed requestId);

    /// @dev Alongside `Pausable`'s own `Paused`, not instead of it. The halt generation is documented
    /// as published so an observer can tell which halt a confirmed unpause belongs to, and `Paused`
    /// cannot carry it — its signature belongs to OpenZeppelin. It was the one generation counter that
    /// advanced without saying so, while the four seat counters all name theirs.
    ///
    /// No matching event on the way back out: `_unpause` does not touch the counter, so `Unpaused`
    /// already carries everything that changed.
    event HaltRaised(address indexed raisedBy, uint32 pauseEpoch);

    event QuotaChanged(uint256 oldQuota, uint256 newQuota, bytes32 evidenceHash);
    event Issued(address indexed inventorySafe, uint256 amount, bytes32 evidenceHash);
    event InventorySafeChanged(address indexed oldSafe, address indexed newSafe, uint32 inventoryEpoch);
    event SettlementAddressChanged(address indexed oldAddress, address indexed newAddress, uint32 settlementEpoch);
    event ShareRatioChanged(
        uint256 oldNumerator, uint256 oldDenominator, uint256 newNumerator, uint256 newDenominator, bytes32 evidenceHash
    );
    event OwnerSafeChanged(address indexed oldSafe, address indexed newSafe, uint32 ownerEpoch);
    event ConfirmerSafeChanged(address indexed oldSafe, address indexed newSafe, uint32 confirmerEpoch);
    event IssuanceClosedForever(bytes32 evidenceHash);
    event Retired(address indexed settlementAddress, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidShareRatio();
    error RequestNotProposed();
    error RequestNotConfirmed();
    error RequestNotReady();
    error RequestWindowClosed();
    error RequestNotExpired();
    error RequestRequiresAcceptance();
    error RequestRequiresExecution();
    error RequestNotCancellable();
    error RequestNotVetoable();
    error QuotaBelowTotalSupply(uint256 quota, uint256 currentTotalSupply);
    error QuotaExceeded(uint256 quota, uint256 resultingTotalSupply);
    error IssuanceAlreadyClosed();
    error IssuanceNotClosed();
    error InventorySafeMoved(address proposedSafe, address currentSafe);
    error CandidateAlreadySeated(address seat);
    error SettlementAddressNotDistinct(address collidingSeat);
    error StaleSeatEpoch(uint32 expectedSeatEpoch, uint32 currentSeatEpoch);
    error StaleRoleEpoch(
        uint32 expectedOwnerEpoch, uint32 currentOwnerEpoch, uint32 expectedConfirmerEpoch, uint32 currentConfirmerEpoch
    );
    error StalePauseEpoch(uint32 expectedPauseEpoch, uint32 currentPauseEpoch);
    error UnsupportedRequestKind();

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    /// @param genesisAmount_ Tokens minted to the inventory Safe in this transaction, and the opening
    /// issuance quota. Zero restores the vendor's original behaviour: no genesis batch at all.
    /// @param deploymentEvidenceHash Hash of the business file authorising this deployment. Recorded
    /// in the event trail only; the contract never reads it back.
    ///
    /// @dev MODIFIED BY PAIMON. The vendor's constructor minted nothing and opened no quota, and its
    /// comment here said why: the first batch went through the same proposal, approval and delay as
    /// every later batch, so there was no "genesis" path the two-role rule did not cover.
    ///
    /// There now is one. A non-zero `genesisAmount_` is minted on the deployer's signature alone —
    /// no Confirmer approval, no waiting period, no request record. Everything issued after it still
    /// takes both roles and the full delay, so this is the single exception, not a general loosening.
    /// It exists because the business required Tokens to be on chain at deployment rather than 72
    /// hours later. Read the banner at the top of this file before changing anything here.
    ///
    /// The quota is opened to exactly the minted figure, not left at zero. A genesis mint without it
    /// would leave `issuanceQuota (0) < totalSupply`, a state no ordinary path can produce, and would
    /// silently constrain the first real quota proposal to be at least the genesis figure or revert
    /// with `QuotaBelowTotalSupply`.
    ///
    /// The genesis batch reports itself through `QuotaChanged` and `Issued` — the same events every
    /// later batch uses — so an indexer already following those sees it in the same stream. A new
    /// event would have made the largest batch the one existing tooling could not see.
    ///
    /// The inventory Safe is a deployment parameter even though the design only describes *replacing*
    /// it: without one there is no receiver to lock into a first issuance request, and the alternative
    /// is a 24-hour replacement dance against a zero address before anything can be issued.
    constructor(
        string memory name_,
        string memory symbol_,
        address ownerSafe_,
        address confirmerSafe_,
        address inventorySafe_,
        uint256 genesisAmount_,
        bytes32 deploymentEvidenceHash
    ) ERC20(name_, symbol_) {
        // One call rather than the six spelled out here, so the deploy script's verdict can staticcall
        // the same function and cover the pairwise rule it used to say nothing about. See
        // `SafeIntrospection.requireApprovedTrio` for why the fetches are not deduplicated and why the
        // separation is three-way rather than between the two governing roles only.
        SafeIntrospection.requireApprovedTrio(ownerSafe_, confirmerSafe_, inventorySafe_);

        ownerSafe = ownerSafe_;
        confirmerSafe = confirmerSafe_;
        inventorySafe = inventorySafe_;

        sharesPerTokenNumerator = 1;
        sharesPerTokenDenominator = 1;

        emit Deployed(ownerSafe_, confirmerSafe_, inventorySafe_, deploymentEvidenceHash);
        // The opening ratio goes out through the event that owns the ratio, rather than as two more
        // fields on `Deployed`, so `ShareRatioChanged` is authoritative for that value for the whole
        // life of the contract — an indexer following it alone is never without a current figure. A
        // zero previous fraction reads as "there was none", the same way the first
        // `SettlementAddressChanged` reports a zero previous address.
        emit ShareRatioChanged(0, 0, 1, 1, deploymentEvidenceHash);

        // PAIMON ADDITION. Guarded rather than unconditional so a zero argument leaves the vendor's
        // original behaviour intact and emits no "changed to zero" events for an indexer to
        // misread. Ordered to mirror `_executeQuotaChange` then `_executeIssuance`, which is what
        // every later batch runs: write the quota, announce it, mint, announce the mint.
        //
        // `_mint` routes through the overridden `_update`, so the pause gate applies here as it does
        // everywhere else — irrelevant at construction, where nothing is paused yet, but it means
        // this path carries no exemption the others lack.
        if (genesisAmount_ != 0) {
            issuanceQuota = genesisAmount_;
            emit QuotaChanged(0, genesisAmount_, deploymentEvidenceHash);

            _mint(inventorySafe_, genesisAmount_);
            emit Issued(inventorySafe_, genesisAmount_, deploymentEvidenceHash);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Proposals
    // ---------------------------------------------------------------------------------------------

    /// @notice Owner proposes a new public issuance quota.
    /// @dev The quota is a *current* ceiling, not a lifetime cap, so a proposal may lower it as well
    /// as raise it. Whether the new value clears total supply is checked at execution rather than
    /// here: issuance can settle during the 72-hour wait, so the answer at proposal time is not the
    /// answer that matters.
    function proposeQuota(uint256 newQuota, bytes32 evidenceHash) external returns (uint256 requestId) {
        requestId = _propose(RequestKind.IncreaseQuota, evidenceHash);
        proposedQuota[requestId] = newQuota;
    }

    /// @notice Owner proposes one batch of Tokens to be minted to the inventory Safe.
    /// @param expectedInventorySafe The inventory Safe the Owner believes is active. Stating it makes
    /// the proposal fail loudly if the receiver has already moved, rather than being silently
    /// re-targeted at whatever the current Safe happens to be.
    /// @dev Each batch is its own request; nothing here excludes another issuance from being in flight
    /// at the same time. Whether the batch fits under the quota is decided at execution, because other
    /// batches can settle during the wait.
    function proposeIssuance(uint256 amount, address expectedInventorySafe, bytes32 evidenceHash)
        external
        returns (uint256 requestId)
    {
        requestId = _propose(RequestKind.Issuance, evidenceHash);
        if (amount == 0) revert InvalidAmount();

        address activeInventorySafe = inventorySafe;
        if (expectedInventorySafe != activeInventorySafe) {
            revert InventorySafeMoved(expectedInventorySafe, activeInventorySafe);
        }

        proposedIssuance[requestId] = IssuanceTerms({amount: amount, inventorySafe: activeInventorySafe});
        expectedSeatEpoch[requestId] = inventoryEpoch;
    }

    /// @notice Owner proposes a replacement inventory Safe. The candidate must accept before it takes
    /// effect, and the checks below run again at that point — this pass only fails obviously
    /// unsuitable candidates early, while the Owner's signers are still in the room.
    /// @dev No disjointness check against the *outgoing* inventory Safe: it is being replaced, so an
    /// overlap with it carries no meaning. Not gated on issuance being open either, deliberately —
    /// `_requiresOpenIssuance` omits it, and `_requireIssuanceOpen` says why custody sits outside.
    function proposeInventorySafe(address newSafe, bytes32 evidenceHash) external returns (uint256 requestId) {
        // `_propose` first because it is what rejects a caller with no standing. Nothing that reaches
        // outside this contract may run on behalf of someone who is not the proposing role — the
        // admission checks below are five external calls against addresses the caller chose.
        requestId = _propose(RequestKind.ReplaceInventorySafe, evidenceHash);
        _requireCandidateNotAlreadySeated(newSafe, inventorySafe);
        _requireApprovedAndDisjointFrom(newSafe, ownerSafe, confirmerSafe);
        proposedAddress[requestId] = newSafe;
        expectedSeatEpoch[requestId] = inventoryEpoch;
    }

    /// @notice Owner proposes the address allowed to retire Tokens it holds once issuance is closed.
    /// @dev No Safe admission checks: the settlement address is not being given authority over anyone
    /// else's balance, only the ability to destroy Tokens already transferred to it, so requiring a
    /// 2-of-3 there would be a constraint the design does not ask for. Answering `acceptRequest` is
    /// the only property that matters, and it proves the address is controllable.
    ///
    /// Unaffected by closure, and it is the one kind for which that is load-bearing rather than
    /// merely allowed: retirement only becomes relevant after issuance ends, so gating this on
    /// issuance being open would make the seat unrotatable for the entire period it is in use.
    function proposeSettlementAddress(address newSettlementAddress, bytes32 evidenceHash)
        external
        returns (uint256 requestId)
    {
        requestId = _propose(RequestKind.ReplaceSettlementAddress, evidenceHash);
        if (newSettlementAddress == address(0)) revert InvalidAddress();
        _requireCandidateNotAlreadySeated(newSettlementAddress, settlementAddress);
        _requireSettlementAddressDistinct(newSettlementAddress);
        proposedAddress[requestId] = newSettlementAddress;
        expectedSeatEpoch[requestId] = settlementEpoch;
    }

    /// @notice Owner proposes the number of shares one Token represents, as an exact fraction.
    /// @dev Both terms must be non-zero. A zero denominator is meaningless and a zero numerator would
    /// publish "one Token represents nothing", which is a statement no corporate action produces.
    function proposeShareRatio(uint256 numerator, uint256 denominator, bytes32 evidenceHash)
        external
        returns (uint256 requestId)
    {
        requestId = _propose(RequestKind.UpdateShareRatio, evidenceHash);
        if (numerator == 0 || denominator == 0) revert InvalidShareRatio();
        proposedShareRatio[requestId] = ShareRatio({numerator: numerator, denominator: denominator});
    }

    /// @notice Owner asks for transfers to be restored. Only available while a halt is in force.
    /// @dev `whenPaused` is load-bearing, not a convenience check. Without it an unpause could be
    /// approved during normal trading and left confirmed for the length of its window, ready to be
    /// spent the instant an incident pause landed — which would leave that incident no deliberation
    /// period at all.
    function proposeUnpause(bytes32 evidenceHash) external returns (uint256 requestId) {
        requestId = _propose(RequestKind.Unpause, evidenceHash);
        // In the body, not as a `whenPaused` modifier: a modifier runs before the body and would be
        // the one place validation still preceded authorisation.
        _requirePaused();
    }

    /// @notice Confirmer nominates a successor Owner Safe; the current Owner approves it.
    /// @dev Mutual by construction — `rolesFor` gives this kind to the Confirmer — so no role can
    /// nominate its own successor. The flip side is the recovery boundary: if an entire role Safe is
    /// lost or simply refuses, its replacement can never be approved and the only remaining move is
    /// rotating individual signers inside that Safe.
    function proposeOwnerReplacement(address candidateSafe, bytes32 evidenceHash) external returns (uint256 requestId) {
        return _proposeRoleReplacement(RequestKind.ReplaceOwner, candidateSafe, evidenceHash);
    }

    /// @notice Owner nominates a successor Confirmer Safe; the current Confirmer approves it.
    function proposeConfirmerReplacement(address candidateSafe, bytes32 evidenceHash)
        external
        returns (uint256 requestId)
    {
        return _proposeRoleReplacement(RequestKind.ReplaceConfirmer, candidateSafe, evidenceHash);
    }

    /// @notice Owner proposes to disable new issuance permanently.
    /// @dev The one governed action with no delay and no execution window: the Confirmer's approval
    /// applies it in the same transaction, so there is never a confirmed-but-pending closure that
    /// could be raced or vetoed. Before confirmation it is an ordinary business request, so the Owner
    /// can withdraw it and the Confirmer can veto it like anything else.
    function proposeIssuanceClosure(bytes32 evidenceHash) external returns (uint256 requestId) {
        requestId = _propose(RequestKind.CloseIssuance, evidenceHash);
    }

    // ---------------------------------------------------------------------------------------------
    // Request lifecycle
    //
    // This is a second delayed-governance machine in the same repository; SpotVesting has one too, and
    // reviewers keep asking why they are not one shared abstraction. Because they agree on almost
    // nothing below the surface: this one needs two roles and a confirmation step where that one has a
    // single proposer plus a veto, per-kind delays where that one has a single delay, payloads stored
    // in the clear where that one keeps a hash and re-submits, and generation counters where that one
    // uses per-resource locks. What they share is `readyAt`/`expiresAt`, which is the shallowest part.
    //
    // The decisive constraint is the other one: SpotVesting is deployed and upgradeable, with its own
    // audited suite behind it. Extracting a common base would mean changing a live contract to serve a
    // maintainability argument about an unreleased one.
    // ---------------------------------------------------------------------------------------------

    /// @notice The second role signs off, which starts the kind's waiting period.
    /// @dev The delay is measured from this block, not from the proposal. Measuring it from the
    /// proposal would let a confirmation arriving near the end of the delay compress the public review
    /// period to almost nothing, which is the one thing the delay exists to provide.
    function confirmRequest(uint256 requestId) external {
        Request storage request = requests[requestId];
        if (request.status != RequestStatus.Proposed) revert RequestNotProposed();

        RequestKind kind = request.kind;
        (, address approver) = rolesFor(kind);
        if (msg.sender != approver) revert Unauthorized();

        // The gate this function used to lack. A request that closure has already killed must not be
        // advanced to `Confirmed`: the approval would be spent on something `executeRequest` refuses
        // for good, and the public record would show a live mint that can never land.
        if (_requiresOpenIssuance(kind)) _requireIssuanceOpen();

        // The same argument as the gate above, for the staleness counters. A draft whose recorded
        // generation has already been passed is dead beyond recovery — the counters only ever move
        // forward and the recorded value never changes — so approving it spends a signature on
        // something `executeRequest` and `acceptRequest` will refuse for good. Worse for the role
        // replacements, where the resulting `Confirmed` record reads as "a new Safe is about to take
        // over governance" when that draft is already void.
        _requireDraftUnsuperseded(requestId, kind, request);

        // Keyed on the delay, not on `kind == CloseIssuance`. A zero delay is what actually forces
        // inline execution, so the delay table stays the single place that decides: a kind entered
        // there with a zero cannot end up with a confirmed-but-pending window by omission, which is
        // the one outcome a zero delay is meant to rule out. Closure is that kind today — the design
        // requires the Confirmer's approval to disable issuance atomically, leaving no interval in
        // which it could be raced or vetoed. That absent interval is also what makes a zero-delay
        // draft the one thing a role rotation has to invalidate — see `_requireDraftUnsuperseded`,
        // which has already run by the time this branch is reached.
        uint64 delay = delayOf(kind);
        if (delay == 0) {
            request.status = RequestStatus.Executed;
            emit RequestConfirmed(requestId, msg.sender, 0, 0);
            emit RequestExecuted(requestId, msg.sender);
            // Through the same effect table as every delayed kind rather than applying the effect
            // here. It used to be inlined behind a hand-written `kind != CloseIssuance` revert, which
            // made this a second dispatch point for effects — one more place a tenth kind has to be
            // wired into, in a contract whose whole shape is one table per concern. `_applyExecution`
            // is total over the nine kinds and reverts on anything it does not recognise, so the
            // tripwire that guard provided is still there, just not written twice.
            _applyExecution(requestId, kind, request);
            return;
        }

        uint64 readyAt = uint64(block.timestamp) + delay;
        uint64 expiresAt = readyAt + EXECUTION_WINDOW;

        request.status = RequestStatus.Confirmed;
        request.readyAt = readyAt;
        request.expiresAt = expiresAt;

        emit RequestConfirmed(requestId, msg.sender, readyAt, expiresAt);
    }

    /// @notice Anyone may execute a matured request. The executor cannot alter it: every parameter was
    /// fixed at proposal time and is read back from storage here.
    function executeRequest(uint256 requestId) external {
        Request storage request = requests[requestId];
        RequestKind kind = _requireMatured(request);
        if (requiresCandidateAcceptance(kind)) revert RequestRequiresAcceptance();

        // Terminalised before the effect runs, so a request can never be executed twice — including
        // from inside anything the effect itself triggers.
        request.status = RequestStatus.Executed;
        emit RequestExecuted(requestId, msg.sender);

        _applyExecution(requestId, kind, request);
    }

    /// @notice The named counterparty takes up the role or address a matured request assigns it.
    /// @dev Acceptance rather than execution for the four kinds that hand authority to an address:
    /// answering here proves the candidate exists, is controllable, and agrees — none of which an
    /// Owner-and-Confirmer pair can establish on the candidate's behalf.
    function acceptRequest(uint256 requestId) external {
        Request storage request = requests[requestId];
        RequestKind kind = _requireMatured(request);
        if (!requiresCandidateAcceptance(kind)) revert RequestRequiresExecution();
        if (msg.sender != proposedAddress[requestId]) revert Unauthorized();

        request.status = RequestStatus.Executed;
        emit RequestAccepted(requestId, msg.sender);

        _applyAcceptance(requestId, kind, request, msg.sender);
    }

    /// @notice The proposing role withdraws a request it raised.
    /// @dev "It" means the role, not the address that sent the proposal — which is why `Request`
    /// stores no proposer. After a rotation the incoming Safe may withdraw requests standing in its
    /// role's name and the outgoing one may not, which is the right way round: a Safe that has been
    /// rotated out must keep no lever over pending business.
    ///
    /// Role replacement carries an extra allowance: either participating current role may pull it
    /// before the candidate accepts. That is not a convenience — the generic Confirmer veto below
    /// deliberately does not reach role replacement, so without this the approving role would have no
    /// way to stop one it had already signed.
    function cancelOwnRequest(uint256 requestId) external {
        Request storage request = requests[requestId];
        RequestKind kind = _requireCancellable(request);

        (address proposer, address approver) = rolesFor(kind);
        bool authorised = msg.sender == proposer || (_isRoleReplacement(kind) && msg.sender == approver);
        if (!authorised) revert Unauthorized();

        request.status = RequestStatus.Cancelled;
        emit RequestWithdrawn(requestId, msg.sender);
    }

    /// @notice Confirmer stops an ordinary business request, including one it confirmed itself.
    /// @dev Vetoing something it already approved is the point, not an oddity: a decision that turns
    /// out to be wrong has to stay stoppable for the whole waiting period, or the delay protects
    /// nothing the Confirmer can act on.
    ///
    /// Role replacement is excluded, so a Confirmer cannot unilaterally block its own replacement —
    /// that flow has the mutual withdrawal rule above instead. An issuance-closure proposal is
    /// reachable here only before confirmation, because confirming one executes it in the same
    /// transaction and leaves nothing pending to veto.
    function vetoRequest(uint256 requestId) external {
        Request storage request = requests[requestId];
        RequestKind kind = _requireCancellable(request);

        // Non-vetoability is a property of the kind, not of the caller, so it is settled before
        // authorisation — the reverse order answered `Unauthorized` to the incumbent role asking to
        // veto its own replacement, which is a true statement about a false reason. This does not
        // weaken the `propose*` rule that authorisation comes first: there it guards caller-supplied
        // arguments and external calls, whereas `kind` is already public in `requests[requestId]`, and
        // `_requireCancellable` above is likewise a request-state gate open to anyone.
        if (_isRoleReplacement(kind)) revert RequestNotVetoable();

        // From the same table `_propose` and `confirmRequest` read, rather than a hardcoded
        // `confirmerSafe`. The literal agreed with the table only as long as role replacement — the
        // one kind whose approver is not the Confirmer — stayed excluded one line above, so the two
        // definitions were kept in step by a coincidence nothing enforced.
        (, address approver) = rolesFor(kind);
        if (msg.sender != approver) revert Unauthorized();

        request.status = RequestStatus.Cancelled;
        emit RequestVetoed(requestId, msg.sender);
    }

    /// @notice Permissionless bookkeeping once a confirmed request's window has closed.
    /// @dev Purely a record-keeping call — an unexpired-but-lapsed request is already unexecutable
    /// because `_requireMatured` checks the window. It exists so the public status says *why* the
    /// request never took effect instead of leaving it indistinguishable from one still in flight.
    function expireRequest(uint256 requestId) external {
        Request storage request = requests[requestId];
        if (request.status != RequestStatus.Confirmed) revert RequestNotConfirmed();
        if (block.timestamp < request.expiresAt) revert RequestNotExpired();

        request.status = RequestStatus.Expired;
        emit RequestExpired(requestId);
    }

    // ---------------------------------------------------------------------------------------------
    // Immediate actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Owner halts all transfers immediately, with no second approval and no delay.
    /// @dev Asymmetric on purpose: an incident may not leave time to collect a second signature set,
    /// while restarting the market does. Restoring transfers goes through `proposeUnpause`, so the
    /// role that stopped trading cannot also reopen it on its own.
    function pause() external {
        if (msg.sender != ownerSafe) revert Unauthorized();
        // Before `_pause()`, which reverts if a halt is already in force — so the counter advances
        // exactly once per halt and can never be bumped by a redundant call.
        uint32 newEpoch = pauseEpoch + 1;
        pauseEpoch = newEpoch;
        emit HaltRaised(msg.sender, newEpoch);
        _pause();
    }

    /// @notice The settlement address destroys Tokens it already holds, recording that the claims
    /// they represent have been discharged.
    /// @dev Records retirement and nothing else: it does not check whether the holder was entitled to
    /// settle, and it does not compute or move any payment. Those are off-chain.
    ///
    /// Burning only its own balance is the whole design. It means no Token can be destroyed unless its
    /// holder voluntarily transferred it here, which is how this coexists with the rule that no role
    /// may burn a user's or a pool's balance — this is an address giving up its own balance, not a
    /// privilege over anyone else's.
    ///
    /// Gated on closure because a burn lowers total supply and so widens the gap to the quota. With
    /// issuance still open, every retirement would hand back mintable room and the claims outstanding
    /// could be silently restored; with issuance permanently closed there is no path into that room.
    ///
    /// Not exempt from the pause. The transfer that hands Tokens in is already blocked while trading
    /// is halted, so exempting the burn would only produce "cannot receive, but can destroy" — and
    /// un-retired Tokens sit inertly here until the halt lifts, with nobody else able to touch them.
    function retireFromSettlement(uint256 amount) external {
        if (msg.sender != settlementAddress) revert Unauthorized();
        if (!issuanceClosed) revert IssuanceNotClosed();
        if (amount == 0) revert InvalidAmount();

        _burn(msg.sender, amount);
        emit Retired(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The waiting period a confirmed request of this kind must sit through.
    /// @dev Public so the schedule can be read off-chain without trusting a copy of it.
    ///
    /// Every kind is listed, the zero included, and anything unmatched reverts. A bare `return 0`
    /// fallthrough would make "no delay at all" the default answer for a kind nobody remembered to
    /// add — the single worst value to hand back from a table whose purpose is to slow things down.
    /// `CloseIssuance` genuinely is zero, so it says so instead of arriving there by omission.
    function delayOf(RequestKind kind) public pure returns (uint64) {
        if (kind == RequestKind.Issuance) return ISSUANCE_DELAY;
        if (kind == RequestKind.ReplaceInventorySafe) return INVENTORY_DELAY;
        if (kind == RequestKind.Unpause) return UNPAUSE_DELAY;
        if (kind == RequestKind.IncreaseQuota) return QUOTA_DELAY;
        if (kind == RequestKind.ReplaceSettlementAddress) return SETTLEMENT_DELAY;
        if (kind == RequestKind.UpdateShareRatio) return SHARE_RATIO_DELAY;
        if (_isRoleReplacement(kind)) return ROLE_CHANGE_DELAY;
        if (kind == RequestKind.CloseIssuance) return 0;
        revert UnsupportedRequestKind();
    }

    /// @notice Which Safe may propose a request of this kind, and which one must approve it.
    /// @dev Returned as a pair, not by two mirror-image lookups. The pair is the property that matters:
    /// if proposer and approver ever resolved to the same Safe for some kind, the two-role approval
    /// would collapse into a single signer with nothing reverting anywhere — the worst failure this
    /// contract can have. Two separate ternaries held that property only by both being edited
    /// correctly; one expression makes a collapse visible in one place, and
    /// `test_RolesForNeverGivesOneSafeBothRoles` walks every kind to say it holds.
    ///
    /// Public for the same reason `delayOf` is: the design's role table should be readable on-chain
    /// rather than trusted from a document.
    ///
    /// Deliberately a default rather than an exhaustive match with a revert, unlike `delayOf`. The
    /// default here is the design's rule for every ordinary kind — Owner proposes, Confirmer approves —
    /// so it is the answer, not a degradation. And a kind added without a case anywhere cannot get
    /// past confirmation regardless: `confirmRequest` calls `delayOf`, which reverts on anything it
    /// does not recognise. The loud failure is already one step downstream.
    function rolesFor(RequestKind kind) public view returns (address proposer, address approver) {
        // Owner replacement is the one kind the Confirmer puts forward, and the Owner being replaced
        // is the one that has to approve it.
        return kind == RequestKind.ReplaceOwner ? (confirmerSafe, ownerSafe) : (ownerSafe, confirmerSafe);
    }

    /// @notice Whether this kind is finished by the named counterparty accepting rather than by anyone
    /// executing. True for exactly the kinds that hand authority or custody to an address.
    /// @dev A positive predicate over four of the nine kinds, so `false` for the others is the answer
    /// and not a fallthrough — unlike `delayOf` above, no value here would be dangerous to default to.
    /// A kind added without thought gets `false`, which routes it to `executeRequest`, where
    /// `_applyExecution` has no case for it and reverts. The tripwire already sits downstream, so
    /// enumerating all nine here would only add a branch that can never fire.
    function requiresCandidateAcceptance(RequestKind kind) public pure returns (bool) {
        return kind == RequestKind.ReplaceInventorySafe || kind == RequestKind.ReplaceSettlementAddress
            || _isRoleReplacement(kind);
    }

    // ---------------------------------------------------------------------------------------------
    // Request internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Called first by every `propose*` entry point, with no exceptions — this is what rejects a
    /// caller who does not hold the proposing role, and authorisation comes before any other check.
    /// Two reasons for that order. The handover proposals reach outside the contract to introspect
    /// Safes the caller named, and none of that should run for someone with no standing. And a single
    /// rule with no exceptions is one less thing to reason about when auditing error precedence: an
    /// unauthorised caller always gets `Unauthorized`, never a hint about argument validity.
    ///
    /// It also applies the one precondition that is a property of the kind rather than of the
    /// arguments — see `_requiresOpenIssuance`. That belongs here for the same reason the
    /// authorisation does: spelled out at each entry point it was a rule three functions had to
    /// remember, and the equivalent rule on `confirmRequest` was simply forgotten.
    ///
    /// Everything after this in a proposal body may revert, which rolls back the id and the record
    /// written here. Nothing observes them in between.
    function _propose(RequestKind kind, bytes32 evidenceHash) private returns (uint256 requestId) {
        (address proposer,) = rolesFor(kind);
        if (msg.sender != proposer) revert Unauthorized();

        // Immediately after authorisation, so the order the entry points used to spell out by hand —
        // authorise, then refuse anything supply-affecting once issuance is closed, then validate
        // arguments — is preserved for all of them at once.
        if (_requiresOpenIssuance(kind)) _requireIssuanceOpen();

        requestId = nextRequestId++;

        // Field-by-field rather than a `Request({...})` literal. Measured, because it looks like it
        // should be the other way round: the literal saves 7 gas on a 128k call and costs 183 bytes of
        // runtime code, because the optimiser already coalesces the same-slot writes. The literal's
        // other argument — that it must name every field, so a new one cannot be forgotten — buys
        // nothing here either: request ids are never reused, so this always writes a fresh zero slot
        // and an unlisted new field would correctly be zero anyway.
        Request storage request = requests[requestId];
        request.kind = kind;
        request.status = RequestStatus.Proposed;
        request.ownerEpoch = ownerEpoch;
        request.confirmerEpoch = confirmerEpoch;
        request.pauseEpoch = pauseEpoch;
        request.evidenceHash = evidenceHash;

        emit RequestProposed(requestId, kind, msg.sender, evidenceHash);
    }

    function _requireMatured(Request storage request) private view returns (RequestKind) {
        if (request.status != RequestStatus.Confirmed) revert RequestNotConfirmed();
        if (block.timestamp < request.readyAt) revert RequestNotReady();
        // Half-open window: `expiresAt` itself is already out of time, so the last executable second
        // is `expiresAt - 1` and expiry and execution can never both be available.
        if (block.timestamp >= request.expiresAt) revert RequestWindowClosed();
        return request.kind;
    }

    /// @dev Takes `kind` rather than re-reading `request.kind`. The caller already validated it, and
    /// by then it has written `request.status` into the same packed slot, so re-reading costs a warm
    /// SLOAD the optimiser cannot fold away. The clarity matters more than the gas: the kind that was
    /// checked is provably the kind that gets dispatched, instead of that resting on "nothing ever
    /// writes `kind` after proposal".
    ///
    /// Deliberately not generalised to the seat epochs, which reviewers have twice proposed on the
    /// strength of this precedent: `acceptRequest` reads an epoch for the staleness comparison and the
    /// accept helper reads it again for its increment, and threading the first read through would save
    /// a warm SLOAD. It is the wrong value to thread. `kind` is immutable after proposal, so a
    /// parameter and a re-read can never disagree; an epoch is about to be incremented by the very
    /// function receiving it, which is what makes a passed-in copy a stale-value hazard as soon as a
    /// later edit puts anything between the read and the write. The property being bought here — the
    /// checked value is the used value — is exactly what threading a soon-to-change counter gives up.
    function _applyExecution(uint256 requestId, RequestKind kind, Request storage request) private {
        // Re-checked here and not trusted from proposal or confirmation, because closure can land
        // inside the delay window. On the dispatch rather than inside each executor, so the set of
        // gated kinds is stated once.
        if (_requiresOpenIssuance(kind)) _requireIssuanceOpen();
        _requireDraftUnsuperseded(requestId, kind, request);

        if (kind == RequestKind.IncreaseQuota) {
            _executeQuotaChange(requestId, request.evidenceHash);
            return;
        }
        if (kind == RequestKind.Issuance) {
            _executeIssuance(requestId, request.evidenceHash);
            return;
        }
        if (kind == RequestKind.Unpause) {
            // Straight to `_unpause()`, which reverts if no halt is in force — so an unpause cannot be
            // replayed against a live market, and `_requireDraftUnsuperseded` above is what stops it
            // being replayed against a *different* halt. Once the epoch check moved out to the shared
            // guard there was nothing left for a per-kind executor to do.
            _unpause();
            return;
        }
        if (kind == RequestKind.UpdateShareRatio) {
            _executeShareRatioChange(requestId, request.evidenceHash);
            return;
        }
        if (kind == RequestKind.CloseIssuance) {
            // Reached from `confirmRequest`, never from `executeRequest`: a zero delay means
            // confirmation is the execution, so closure never sits in `Confirmed` for the
            // permissionless executor to find. It is dispatched here anyway so that this is the only
            // table mapping a kind to its effect.
            _closeIssuance(request.evidenceHash);
            return;
        }
        // A kind with no case above. Loud rather than falling through to the last branch, because this
        // contract cannot be patched and a new action must fail visibly instead of being mistaken for
        // a share-ratio change.
        revert UnsupportedRequestKind();
    }

    /// @dev Same reasoning as `_applyExecution` for taking `kind` as a parameter.
    function _applyAcceptance(uint256 requestId, RequestKind kind, Request storage request, address acceptor) private {
        // Before the dispatch, which keeps the order each branch used to arrange for itself: staleness
        // is the cheaper and more specific answer, so a superseded draft says so rather than
        // complaining about the candidate's Safe.
        _requireDraftUnsuperseded(requestId, kind, request);

        if (kind == RequestKind.ReplaceInventorySafe) {
            _acceptInventorySafe(acceptor);
        } else if (kind == RequestKind.ReplaceSettlementAddress) {
            _acceptSettlementAddress(acceptor);
        } else if (_isRoleReplacement(kind)) {
            _acceptRoleReplacement(kind, acceptor);
        } else {
            // Unreachable: `acceptRequest` already rejected every kind for which
            // `requiresCandidateAcceptance` is false, and the three branches above cover all four for
            // which it is true. Same reasoning as `_applyExecution` for keeping it.
            revert UnsupportedRequestKind();
        }

        _requireSettlementSeatSeparation();
    }

    /// @dev The settlement/seat separation, enforced as a post-condition on the shared acceptance path
    /// rather than as an argument check on each proposal. That placement is the point: the rule is
    /// symmetric — settlement must not become a seat, and a seat must not become settlement — and
    /// writing it as two argument checks is what left the second direction open the first time. Here
    /// there is one definition, it runs after whichever of the four handovers just landed, and a fifth
    /// seat added later cannot bypass it without leaving this path.
    ///
    /// Zero settlement address short-circuits: before the seat is filled there is nothing to collide.
    ///
    /// The consequence to know about, because it is not an accident: a candidate nominated for two
    /// seats at once can only ever take one. Both proposals pass, because each is only held against
    /// the seats' *current* occupants; the first acceptance lands, and the second reverts here — a
    /// request that carried both approvals and sat out its whole delay, killed at the last step. It
    /// then expires like anything else, and nothing on-chain warned at confirmation time that it was
    /// already doomed.
    ///
    /// The other seat pairings reach the same end through their own guards, which is why this rule is
    /// not the general statement of it: a candidate holding a role seat and then accepting an inventory
    /// handover — or the reverse — is refused by the acceptance-time disjointness re-check, comparing
    /// the candidate's owner list against itself; two role seats are cut off earlier still, because
    /// either role moving invalidates every outstanding replacement draft through `StaleRoleEpoch`.
    ///
    /// Detecting it earlier would mean a registry of pending candidates keyed by seat, kept correct
    /// across withdrawal, veto, expiry and epoch invalidation — permanent storage and four more
    /// write paths, to convert a revert into an earlier revert. The mistake is caught either way,
    /// the roles that made it are the ones who pay for it, and no third party can provoke it.
    function _requireSettlementSeatSeparation() private view {
        address settlement = settlementAddress;
        if (settlement == address(0)) return;

        _requireNotASeat(settlement);
    }

    /// @dev The three-way comparison both settlement checks need, in one place. They are separate
    /// checkpoints for good reasons — one fails a candidate fast at proposal, the other is the
    /// post-condition that actually enforces the rule after a handover — but the comparison itself had
    /// no reason to be written twice. A fourth seat is now one edit rather than two that a compiler
    /// cannot pair up, and getting only one of them would have shown up as a settlement address
    /// silently sharing the new seat.
    function _requireNotASeat(address candidate) private view {
        if (candidate == ownerSafe) revert SettlementAddressNotDistinct(ownerSafe);
        if (candidate == confirmerSafe) revert SettlementAddressNotDistinct(confirmerSafe);
        if (candidate == inventorySafe) revert SettlementAddressNotDistinct(inventorySafe);
    }

    /// @dev Both statuses are cancellable and neither terminal one is: cancelling reaches a request
    /// the other role has already signed and a ready-but-unexecuted one alike, and never reverses an
    /// action that has landed.
    function _requireCancellable(Request storage request) private view returns (RequestKind) {
        RequestStatus status = request.status;
        if (status != RequestStatus.Proposed && status != RequestStatus.Confirmed) {
            revert RequestNotCancellable();
        }
        // A confirmed request past its window is already dead on its own. Stamping it Cancelled would
        // make the public record answer "a role stopped this" where the truth is "nobody acted".
        if (status == RequestStatus.Confirmed && block.timestamp >= request.expiresAt) {
            revert RequestWindowClosed();
        }
        return request.kind;
    }

    /// @dev Staleness guard for anything drafted against a seat: the two custody handovers and every
    /// issuance. Nothing excludes two of them being approved
    /// at once, so the loser of the race is left confirmed and inside its window after the winner has
    /// landed; accepting it then would hand custody back to a candidate the roles have already moved
    /// on from, with no fresh approval in the transaction. Where the second handover was prompted by
    /// the first candidate turning out to be compromised, that is the compromised address reclaiming
    /// every future mint, or the right to burn what gets handed in.
    ///
    /// A monotonic per-seat counter, not a comparison against the incumbent's address. The address
    /// form has a hole: hand the seat to B and then back to A, and a draft written when A held it
    /// matches again, so a superseded candidate could still take the seat on an approval two
    /// reassignments old. A counter only ever moves forward.
    ///
    /// Per seat rather than one global counter, which keeps the precision the address form had: an
    /// inventory handover must not invalidate a settlement draft that is still perfectly valid.
    /// The two role replacements use their own pair of counters for the same reason, except theirs
    /// must fire on *either* role moving — see `_requireRoleEpochsUnmoved`. `_requirePauseEpochUnmoved`
    /// is the third of these, guarding against an approval earned during one halt being spent on the
    /// next. Three guards rather than one primitive because each raises a different error on purpose —
    /// the failure should say *which* staleness it is — and Solidity cannot take the error as a
    /// parameter. Which of the three applies to a given kind is `_requireDraftUnsuperseded`.
    function _requireSeatEpochUnmoved(uint256 requestId, uint32 currentSeatEpoch) private view {
        uint32 expected = expectedSeatEpoch[requestId];
        if (expected != currentSeatEpoch) revert StaleSeatEpoch(expected, currentSeatEpoch);
    }

    /// @dev Both pairs in the payload rather than a bare error: the three staleness guards are meant to
    /// read alike, and an off-chain monitor should be able to say *which* seat moved from the revert
    /// data instead of having to go and read the counters back.
    function _requireRoleEpochsUnmoved(Request storage request) private view {
        if (request.ownerEpoch != ownerEpoch || request.confirmerEpoch != confirmerEpoch) {
            revert StaleRoleEpoch(request.ownerEpoch, ownerEpoch, request.confirmerEpoch, confirmerEpoch);
        }
    }

    function _requirePauseEpochUnmoved(uint32 raisedUnderPauseEpoch) private view {
        if (raisedUnderPauseEpoch != pauseEpoch) revert StalePauseEpoch(raisedUnderPauseEpoch, pauseEpoch);
    }

    /// @dev Which counter kills which draft, in one dispatch that confirmation, execution and
    /// acceptance all read.
    ///
    /// It was five separate call sites — two branches of `_applyAcceptance`, and one apiece inside
    /// `_acceptRoleReplacement`, `_executeIssuance` and the unpause branch — which is why nobody
    /// noticed the phase that had none of them: `confirmRequest` re-validated nothing, so every kind
    /// listed here could be approved after its draft was already void. Fixing that by adding a sixth
    /// hand-written mapping would have been the same mistake in a new place.
    ///
    /// The unmatched kinds are unmatched on purpose, not by omission. `IncreaseQuota` and
    /// `UpdateShareRatio` are drafted against no seat and no halt: two approved quota values are both
    /// legitimate and the later execution simply wins, which is a documented ordering exposure rather
    /// than staleness. The role generations, though recorded on every request, are compared for the
    /// role replacements and for anything with no delay — invalidating *delayed* business on every
    /// role rotation would be a far larger rule than the design asks for, and there the incoming Safe
    /// can withdraw or veto during the window. `CloseIssuance` was in the unmatched list until an
    /// audit pointed out it has no window, so nothing made that remedy reachable.
    function _requireDraftUnsuperseded(uint256 requestId, RequestKind kind, Request storage request) private view {
        if (kind == RequestKind.Issuance || kind == RequestKind.ReplaceInventorySafe) {
            _requireSeatEpochUnmoved(requestId, inventoryEpoch);
        } else if (kind == RequestKind.ReplaceSettlementAddress) {
            _requireSeatEpochUnmoved(requestId, settlementEpoch);
        } else if (_isRoleReplacement(kind)) {
            _requireRoleEpochsUnmoved(request);
        } else if (kind == RequestKind.Unpause) {
            _requirePauseEpochUnmoved(request.pauseEpoch);
        } else if (delayOf(kind) == 0) {
            // Keyed on the delay, not on `kind == CloseIssuance`, because the delay is what creates the
            // exposure. Every delayed kind is deliberately *not* invalidated by a role rotation, and
            // the reason recorded in `PreIPOTokenTypes` is that the incoming role has a remedy: it can
            // withdraw or veto during the window. A zero delay is exactly where that reason runs out —
            // confirmation *is* the execution, so there is no window and the remedy is a race the
            // incoming role can lose.
            //
            // Left unchecked, a closure proposal abandoned by a former Owner stayed live across the
            // handover and the Confirmer alone could apply it, setting `issuanceClosed` forever with
            // the current Owner never asked. That is the one irreversible action in the contract, and
            // the design specifies it as two roles agreeing — not one current role plus a predecessor.
            //
            // Both generations rather than just the proposer's, which would be the minimal expression
            // of "the proposer is still the proposer": naming the proposer's seat means branching on
            // `rolesFor` again to know which counter to read, and that is the role table written a
            // second time — the duplication that had `vetoRequest` authorising against a hardcoded
            // `confirmerSafe` until a review caught it. The extra strictness costs a re-proposal after
            // a Confirmer rotation, which for a once-ever action taken deliberately at the IPO is not
            // a cost worth buying a duplicated table to avoid.
            _requireRoleEpochsUnmoved(request);
        }
    }

    function _isRoleReplacement(RequestKind kind) private pure returns (bool) {
        return kind == RequestKind.ReplaceOwner || kind == RequestKind.ReplaceConfirmer;
    }

    /// @dev Which kinds may only move while issuance is open — the three that can add supply, and
    /// nothing else. See `_requireIssuanceOpen` for why the handovers and the share ratio sit outside.
    ///
    /// A table read by all three phases rather than a check spelled out at each site. It was spelled
    /// out, and the middle phase was missing: `propose` and `execute` both gated, `confirm` did not, so
    /// after closure the Confirmer could still advance an issuance or quota request to `Confirmed`,
    /// spending an approval on something `execute` would refuse forever and leaving a dead request
    /// looking like a live mint. Adding a second hand-written list to `confirmRequest` would have
    /// bought the same drift back, so the list lives here once.
    function _requiresOpenIssuance(RequestKind kind) private pure returns (bool) {
        return kind == RequestKind.IncreaseQuota || kind == RequestKind.Issuance || kind == RequestKind.CloseIssuance;
    }

    // ---------------------------------------------------------------------------------------------
    // Governed effects
    // ---------------------------------------------------------------------------------------------

    /// @dev The floor is re-derived here rather than captured at proposal time because issuance can
    /// settle during the wait: a quota that cleared total supply three days ago may no longer.
    function _executeQuotaChange(uint256 requestId, bytes32 evidenceHash) private {
        uint256 newQuota = proposedQuota[requestId];
        uint256 currentTotalSupply = totalSupply();
        if (newQuota < currentTotalSupply) revert QuotaBelowTotalSupply(newQuota, currentTotalSupply);

        uint256 oldQuota = issuanceQuota;
        issuanceQuota = newQuota;
        emit QuotaChanged(oldQuota, newQuota, evidenceHash);
    }

    /// @dev Both the receiver and the amount come out of storage, so the permissionless executor
    /// contributes nothing but the gas. What invalidates an issuance drafted against a replaced
    /// inventory Safe is the seat generation, checked by `_requireDraftUnsuperseded` on the shared
    /// dispatch — O(1), where sweeping the pending set at replacement time could not be bounded to fit
    /// a block. The generation and not the receiver address: an address comparison is not a durable
    /// invalidation, since handing the seat away and taking it back makes a draft written before
    /// either move match again. `terms.inventorySafe` below stays because it is the *receiver* — what
    /// stops the permissionless executor redirecting the mint — and with the generation unmoved it is
    /// necessarily still the seated Safe.
    ///
    /// Nothing checks `paused()`: minting routes through `_update`, which is where the global pause
    /// gate lives, so an issuance during an incident already fails there.
    function _executeIssuance(uint256 requestId, bytes32 evidenceHash) private {
        IssuanceTerms memory terms = proposedIssuance[requestId];

        uint256 resultingTotalSupply = totalSupply() + terms.amount;
        uint256 quota = issuanceQuota;
        if (resultingTotalSupply > quota) revert QuotaExceeded(quota, resultingTotalSupply);

        _mint(terms.inventorySafe, terms.amount);
        emit Issued(terms.inventorySafe, terms.amount, evidenceHash);
    }

    /// @dev Re-runs the full admission check at acceptance. The candidate's signer set can have
    /// changed during the 24-hour wait, and it is the shape at handover that the Token has to live
    /// with — the proposal-time pass was only there to fail hopeless candidates early.
    function _acceptInventorySafe(address candidate) private {
        _requireApprovedAndDisjointFrom(candidate, ownerSafe, confirmerSafe);

        address previous = inventorySafe;
        uint32 newEpoch = inventoryEpoch + 1;
        inventorySafe = candidate;
        inventoryEpoch = newEpoch;
        emit InventorySafeChanged(previous, candidate, newEpoch);
    }

    /// @dev Replaceable, which departs from the source document's "set once". A lost settlement
    /// address would otherwise strand the wind-down with no recovery path at all. The exposure this
    /// adds is bounded: whoever holds the right can still only burn Tokens already sitting in its own
    /// balance, so redirecting it moves who may destroy handed-in Tokens, not whose Tokens can be
    /// destroyed.
    ///
    /// It does leave an operational step that nothing here enforces: `retireFromSettlement` burns from
    /// the *current* address, so Tokens already handed in to the outgoing one must be transferred
    /// across before they can be retired. Deliberately not automated. Letting a former address keep
    /// the burn right would grow the privilege set with every rotation, and refusing to rotate until
    /// the outgoing balance is zero would let anyone block a rotation by sending it one wei — the very
    /// rotation that exists to recover from a compromised address.
    function _acceptSettlementAddress(address candidate) private {
        address previous = settlementAddress;
        uint32 newEpoch = settlementEpoch + 1;
        settlementAddress = candidate;
        settlementEpoch = newEpoch;
        emit SettlementAddressChanged(previous, candidate, newEpoch);
    }

    /// @dev Writes two numbers and emits. Deliberately touches no balance, allowance, or supply, and
    /// deliberately outside `_requiresOpenIssuance`: a corporate action can happen after the IPO, and
    /// the design keeps this available once issuance is closed.
    function _executeShareRatioChange(uint256 requestId, bytes32 evidenceHash) private {
        ShareRatio memory ratio = proposedShareRatio[requestId];

        uint256 previousNumerator = sharesPerTokenNumerator;
        uint256 previousDenominator = sharesPerTokenDenominator;
        sharesPerTokenNumerator = ratio.numerator;
        sharesPerTokenDenominator = ratio.denominator;

        emit ShareRatioChanged(previousNumerator, previousDenominator, ratio.numerator, ratio.denominator, evidenceHash);
    }

    /// @dev What stops a role takeover through a stale draft is `_requireRoleEpochsUnmoved`, which
    /// the shared guard runs before this: two Owner replacements can both be approved — nothing
    /// excludes them — so the first candidate to accept becomes Owner while the second still holds a
    /// request approved by the Owner it displaced. Comparing both epochs kills every replacement draft
    /// the moment either role actually moves, including the symmetric case where the *proposing* role
    /// has since been replaced. All this function does is re-admit the candidate and move the seat.
    function _acceptRoleReplacement(RequestKind kind, address candidate) private {
        // The two branches are the same shape and stay separate on purpose. Solidity offers no way to
        // alias a plain `address` state variable behind a storage pointer, and no way to pass an event
        // type as a parameter, so merging them would mean either slot arithmetic or collapsing two
        // typed events into one untyped `SeatChanged` — and this contract's event trail is a
        // deliverable, not an implementation detail. Three separate reviews have filed this as
        // duplication; the duplication is real and the alternatives are worse.
        //
        // The new generation is computed once and then written and emitted, so the number in the event
        // is provably the number in storage rather than a second read that happens to agree.
        if (kind == RequestKind.ReplaceOwner) {
            _requireApprovedAndDisjointFrom(candidate, confirmerSafe, inventorySafe);
            address previous = ownerSafe;
            uint32 newEpoch = ownerEpoch + 1;
            ownerSafe = candidate;
            ownerEpoch = newEpoch;
            emit OwnerSafeChanged(previous, candidate, newEpoch);
        } else {
            _requireApprovedAndDisjointFrom(candidate, ownerSafe, inventorySafe);
            address previous = confirmerSafe;
            uint32 newEpoch = confirmerEpoch + 1;
            confirmerSafe = candidate;
            confirmerEpoch = newEpoch;
            emit ConfirmerSafeChanged(previous, candidate, newEpoch);
        }
    }

    /// @dev Setting the flag is what makes every unexecuted issuance and quota request invalid "in
    /// the same transaction": all of them read it at execution, so one write kills the whole set at
    /// once. Sweeping the pending set instead would be unbounded work in a transaction that must not
    /// be allowed to run out of gas.
    ///
    /// No `_requireIssuanceOpen()` of its own, and it used to have one — for the real case of two
    /// closures in flight, where confirming the second after the first landed should say so rather
    /// than re-emit. `confirmRequest` now gates every kind `_requiresOpenIssuance` names, and closure
    /// is executed inline from there, so that confirmation *is* this function's only caller and has
    /// already refused the case. A second check here would be unreachable, and unreachable checks do
    /// not stay tested.
    function _closeIssuance(bytes32 evidenceHash) private {
        issuanceClosed = true;
        emit IssuanceClosedForever(evidenceHash);
    }

    // ---------------------------------------------------------------------------------------------
    // Guards
    // ---------------------------------------------------------------------------------------------

    /// @dev Why the boundary falls where it does. Which kinds it applies to is `_requiresOpenIssuance`,
    /// and the two are split on purpose: the list has to be readable by all three phases, the reasoning
    /// only has to be readable once. It covers the three kinds that can add supply — quota, issuance,
    /// and closure itself — and none of the four handovers or the share ratio.
    ///
    /// Closing issuance ends minting, not the company. The seats still have to be rotatable through
    /// the wind-down; an inventory Safe lost after the IPO is exactly when a handover is needed, and
    /// gating it would leave unsold inventory stranded in an unusable Safe with no recovery path in a
    /// contract that cannot be upgraded. Settlement is the same argument, more sharply: it is only
    /// *after* closure that retirement matters at all. And a corporate action still has to be
    /// publishable — see `_executeShareRatioChange`.
    ///
    /// The rule, then: anything that could increase supply is gated at proposal, at confirmation, and
    /// again at execution, because closure can land in any of the gaps between them; anything that
    /// only moves who holds a seat, or what one Token represents, is not gated at all.
    function _requireIssuanceOpen() private view {
        if (issuanceClosed) revert IssuanceAlreadyClosed();
    }

    /// @dev The two role replacements differ only in which seat is being vacated and which one stays,
    /// so they share a body. Keeping it in one place is what stops a later change — a new check, a new
    /// recorded field — from being applied to one direction and forgotten on the other.
    ///
    /// The candidate is held against the counterpart role and the inventory Safe, never against the
    /// seat it is replacing: an overlap with a Safe on its way out carries no meaning.
    function _proposeRoleReplacement(RequestKind kind, address candidateSafe, bytes32 evidenceHash)
        private
        returns (uint256 requestId)
    {
        requestId = _propose(kind, evidenceHash);
        // Both seats come out of `rolesFor` after `_propose`, rather than the counterpart arriving as
        // an argument: an argument expression is evaluated at the call site, which put a read of state
        // ahead of the authorisation check and made `_propose`'s "called first, with no exceptions"
        // untrue for exactly these two entry points. Harmless as a bare SLOAD, but the rule is the
        // thing being protected — the next expression put there might not be one.
        //
        // The mapping is exact, not a convenient approximation. A role replacement is nominated by the
        // *other* role and approved by the seat being vacated, so for these kinds `rolesFor` returns
        // (counterpart, incumbent) — the two addresses this needs, in that order.
        //
        // `_propose` already read both seats through the same call and kept only the proposer, so this
        // is a second warm read of each, ~200 gas. Reviewed and left: the alternatives are threading
        // the pair out of `_propose` — a wider return for the seven entry points that have no use for
        // it — or naming the incumbent with a local `kind == ReplaceOwner ? ownerSafe : confirmerSafe`,
        // which is the role table written a second time. Both cost more than 200 gas is worth, and the
        // second is the exact duplication that had `vetoRequest` authorising against a hardcoded
        // `confirmerSafe` until a review caught it.
        (address counterpart, address incumbent) = rolesFor(kind);
        _requireCandidateNotAlreadySeated(candidateSafe, incumbent);
        _requireApprovedAndDisjointFrom(candidateSafe, counterpart, inventorySafe);
        proposedAddress[requestId] = candidateSafe;
    }

    /// @dev A handover onto the address already sitting there is a no-op with a side effect, which is
    /// why it is worth rejecting rather than just pointless: accepting it bumps the seat's generation,
    /// and that invalidates every other draft written against the seat — pending issuances for the
    /// inventory seat, other replacement drafts for a role. Fail-fast, so the accident costs a
    /// transaction instead of a delay window plus somebody else's approved work.
    function _requireCandidateNotAlreadySeated(address candidate, address incumbent) private pure {
        if (candidate == incumbent) revert CandidateAlreadySeated(incumbent);
    }

    /// @dev The settlement address is deliberately not required to be a Safe — its only power is to
    /// destroy Tokens already sitting in its own balance. It must still not *be* one of the three
    /// seats. Sharing a seat would let one address both receive every mint and burn what is handed in,
    /// and worse, it would make burns of unsold inventory indistinguishable from burns of redeemed
    /// holder claims in the `Retired` trail — and that trail is the only thing retirement produces.
    ///
    /// Address equality rather than signer disjointness, because a non-Safe has no signer set to
    /// compare. Fail-fast only; `_requireSettlementSeatSeparation` is what enforces the rule.
    function _requireSettlementAddressDistinct(address candidate) private view {
        // The Token itself: a paste error that nothing downstream would catch in time. It passes
        // confirmation and then can never be accepted, because acceptance requires the candidate to
        // call in and the contract never calls itself — so it silently burns a 72-hour delay and a
        // seven-day window before expiring. The post-condition cannot see this one either, for the
        // same reason: the collision can never actually be reached, only proposed.
        if (candidate == address(this)) revert SettlementAddressNotDistinct(address(this));
        _requireNotASeat(candidate);
    }

    /// @dev The one definition of an address admissible to any of the three seats: an approved Safe
    /// whose signers overlap neither of the two seats that keep their occupant. Held to the same
    /// three-way disjointness the constructor demands, so no sequence of handovers can arrive at a
    /// configuration deployment would refuse.
    ///
    /// Callers name the two retained seats rather than this deriving them, so each call site states
    /// what the candidate is being held against instead of half the rule living in here. The seat
    /// being vacated is deliberately absent: an overlap with a Safe on its way out carries no meaning.
    ///
    /// Applied both when a handover is proposed and again when the candidate accepts. The signer sets
    /// can change in between, and it is the state at acceptance that the Token has to live with.
    function _requireApprovedAndDisjointFrom(address candidate, address retainedSeatA, address retainedSeatB)
        private
        view
    {
        SafeIntrospection.requireApprovedAndDisjoint(candidate, retainedSeatA, retainedSeatB);

        // Fail-fast only; `_requireSettlementSeatSeparation` is what enforces this. Catching it here
        // saves burning a whole 24- or 72-hour cycle on a handover that cannot be accepted.
        if (candidate == settlementAddress) revert SettlementAddressNotDistinct(candidate);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------------------------------

    /// @dev Byte-for-byte what OpenZeppelin's `ERC20Pausable` does, and inheriting that instead was
    /// considered and rejected. Two reasons for keeping it here. This override is load-bearing beyond
    /// transfers — `retireFromSettlement` reasons explicitly about `_burn` routing through it, and
    /// issuance relies on `_mint` doing the same — so a reader of either wants to find the gate in the
    /// same file rather than in a base contract. And this contract can never be patched, so silently
    /// inheriting a future change to pause semantics is a worse failure mode than three lines that a
    /// dependency bump cannot move.
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }
}
