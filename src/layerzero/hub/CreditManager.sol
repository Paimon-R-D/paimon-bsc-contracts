// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ICreditManager} from "../interfaces/ICreditManager.sol";
import {MessageCodec} from "../libraries/MessageCodec.sol";
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";

/// @title CreditManager
/// @notice Manages cross-chain credit allocation using Delta algorithm
/// @dev Deployed on BSC Hub chain, controls credit distribution to remote chains
contract CreditManager is OApp, Pausable, ICreditManager {

    // ========== Errors ==========

    error InvalidAmount();
    error ChainNotSupported(uint32 eid);
    error ChainAlreadySupported(uint32 eid);
    error ChainHasUtilizedCredit(uint32 eid);
    error InsufficientCredit(uint256 available, uint256 required);
    error RestoreExceedsUtilized(uint256 utilized, uint256 amount);
    error CannotReduceBelowUtilized(uint256 utilized, uint256 newCredit);
    error LengthMismatch(uint256 expected, uint256 actual);
    error EmptyArray();
    error NoCreditChange();
    error UnknownMessageType(bytes1 msgType);
    error UnauthorizedSource(uint32 srcEid);

    // ========== Constants ==========

    /// @notice Basis points denominator (100%)
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Default gas limit for cross-chain messages
    uint128 public constant DEFAULT_GAS_LIMIT = 200000;

    // ========== State Variables ==========

    /// @notice Credit allocation per chain (eid => ChainCredit)
    mapping(uint32 => ChainCredit) internal _chainCredits;

    /// @notice Array of supported chain endpoint IDs
    uint32[] internal _supportedChains;

    /// @notice Mapping to check if chain is supported
    mapping(uint32 => bool) internal _isSupported;

    /// @notice Total credits allocated across all chains
    uint256 public override totalCredits;

    // ========== Constructor ==========

    /// @notice Initialize the CreditManager
    /// @param _endpoint LayerZero endpoint address
    /// @param _delegate Owner/delegate address
    constructor(
        address _endpoint,
        address _delegate
    ) OApp(_endpoint, _delegate) Ownable(_delegate) {}

    // ========== View Functions ==========

    /// @inheritdoc ICreditManager
    function credits(uint32 eid) external view override returns (uint256) {
        return _chainCredits[eid].credit;
    }

    /// @inheritdoc ICreditManager
    function getCreditUtilization(uint32 eid) external view override returns (uint256) {
        ChainCredit storage cc = _chainCredits[eid];
        if (cc.credit == 0) return BPS_DENOMINATOR; // 100% utilized if no credit
        return (cc.utilized * BPS_DENOMINATOR) / cc.credit;
    }

    /// @inheritdoc ICreditManager
    function getAvailableCredit(uint32 eid) external view override returns (uint256) {
        ChainCredit storage cc = _chainCredits[eid];
        if (cc.credit <= cc.utilized) return 0;
        return cc.credit - cc.utilized;
    }

    /// @inheritdoc ICreditManager
    function getChainCredit(uint32 eid) external view override returns (ChainCredit memory) {
        return _chainCredits[eid];
    }

    /// @inheritdoc ICreditManager
    function getSupportedChains() external view override returns (uint32[] memory) {
        return _supportedChains;
    }

    // ========== Credit Management ==========

    /// @inheritdoc ICreditManager
    function sendCredits(uint32 dstEid, uint256 amount) external payable override onlyOwner whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (!_isSupported[dstEid]) revert ChainNotSupported(dstEid);

        // Update local state
        uint256 oldCredit = _chainCredits[dstEid].credit;
        uint256 newCredit = oldCredit + amount;
        _chainCredits[dstEid].credit = newCredit;
        _chainCredits[dstEid].lastUpdate = block.timestamp;
        totalCredits += amount;

        _syncCreditAllocation(dstEid, newCredit, msg.value, msg.sender);

        emit CreditsSent(dstEid, amount);
        emit CreditUpdated(dstEid, oldCredit, newCredit);
    }

    /// @inheritdoc ICreditManager
    function reduceCredit(uint32 eid, uint256 amount) external override onlyOwner whenNotPaused {
        _reduceCredit(eid, amount);
    }

    /// @inheritdoc ICreditManager
    function restoreCredit(uint32 eid, uint256 amount) external override onlyOwner whenNotPaused {
        if (!_isSupported[eid]) revert ChainNotSupported(eid);
        if (_chainCredits[eid].utilized < amount) revert RestoreExceedsUtilized(_chainCredits[eid].utilized, amount);

        _chainCredits[eid].utilized -= amount;
        _chainCredits[eid].lastUpdate = block.timestamp;

        emit CreditUtilized(eid, _chainCredits[eid].utilized);
    }

    /// @inheritdoc ICreditManager
    function rebalance(
        uint32[] calldata eids,
        uint256[] calldata amounts
    ) external payable override onlyOwner whenNotPaused {
        if (eids.length != amounts.length) revert LengthMismatch(eids.length, amounts.length);
        if (eids.length == 0) revert EmptyArray();

        uint256 changedChains = 0;
        for (uint256 i = 0; i < eids.length; i++) {
            if (!_isSupported[eids[i]]) revert ChainNotSupported(eids[i]);
            if (amounts[i] < _chainCredits[eids[i]].utilized) {
                revert CannotReduceBelowUtilized(_chainCredits[eids[i]].utilized, amounts[i]);
            }
            if (amounts[i] != _chainCredits[eids[i]].credit) {
                changedChains++;
            }
        }

        if (changedChains == 0) {
            if (msg.value > 0) revert NoCreditChange();
            emit Rebalanced(eids, amounts);
            return;
        }

        uint256 totalFee = msg.value;
        uint256 feePerChangedChain = totalFee / changedChains;
        uint256 totalUsedFee = 0;
        uint256 processedChanges = 0;

        for (uint256 i = 0; i < eids.length; i++) {
            uint256 oldCredit = _chainCredits[eids[i]].credit;
            uint256 newCredit = amounts[i];
            if (newCredit == oldCredit) continue;

            if (newCredit > oldCredit) {
                uint256 delta = newCredit - oldCredit;
                totalCredits += delta;
                emit CreditsSent(eids[i], delta);
            } else if (newCredit < oldCredit) {
                uint256 delta = oldCredit - newCredit;
                totalCredits -= delta;
            }

            _chainCredits[eids[i]].credit = newCredit;
            _chainCredits[eids[i]].lastUpdate = block.timestamp;

            uint256 fee = processedChanges == changedChains - 1 ? (totalFee - totalUsedFee) : feePerChangedChain;
            _syncCreditAllocation(eids[i], newCredit, fee, msg.sender);
            totalUsedFee += fee;
            processedChanges++;

            emit CreditUpdated(eids[i], oldCredit, newCredit);
        }

        emit Rebalanced(eids, amounts);
    }

    /// @inheritdoc ICreditManager
    function setCredit(uint32 eid, uint256 amount) external payable override onlyOwner whenNotPaused {
        if (!_isSupported[eid]) revert ChainNotSupported(eid);
        // Cannot set credit below current utilization
        if (amount < _chainCredits[eid].utilized) revert CannotReduceBelowUtilized(_chainCredits[eid].utilized, amount);

        uint256 oldCredit = _chainCredits[eid].credit;
        if (amount == oldCredit) {
            if (msg.value > 0) revert NoCreditChange();
            return;
        }

        if (amount > oldCredit) {
            totalCredits += (amount - oldCredit);
        } else {
            totalCredits -= (oldCredit - amount);
        }

        _chainCredits[eid].credit = amount;
        _chainCredits[eid].lastUpdate = block.timestamp;
        _syncCreditAllocation(eid, amount, msg.value, msg.sender);

        emit CreditUpdated(eid, oldCredit, amount);
    }

    // ========== Configuration ==========

    /// @inheritdoc ICreditManager
    function addChain(uint32 eid, uint256 initialCredit) external override onlyOwner {
        if (_isSupported[eid]) revert ChainAlreadySupported(eid);

        _isSupported[eid] = true;
        _supportedChains.push(eid);
        _chainCredits[eid] = ChainCredit({
            credit: initialCredit,
            utilized: 0,
            lastUpdate: block.timestamp
        });
        totalCredits += initialCredit;

        emit CreditUpdated(eid, 0, initialCredit);
    }

    /// @inheritdoc ICreditManager
    function removeChain(uint32 eid) external override onlyOwner {
        if (!_isSupported[eid]) revert ChainNotSupported(eid);
        if (_chainCredits[eid].utilized > 0) revert ChainHasUtilizedCredit(eid);

        totalCredits -= _chainCredits[eid].credit;
        _isSupported[eid] = false;
        delete _chainCredits[eid];

        // Remove from array
        for (uint256 i = 0; i < _supportedChains.length; i++) {
            if (_supportedChains[i] == eid) {
                _supportedChains[i] = _supportedChains[_supportedChains.length - 1];
                _supportedChains.pop();
                break;
            }
        }
    }

    // ========== Fee Quoting ==========

    /// @inheritdoc ICreditManager
    function quoteSendCredits(
        uint32 dstEid,
        uint256 amount
    ) external view override returns (uint256 nativeFee, uint256 lzTokenFee) {
        bytes memory payload = MessageCodec.encodeCreditUpdate(amount);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);
        MessagingFee memory fee = _quote(dstEid, payload, options, false);
        return (fee.nativeFee, fee.lzTokenFee);
    }

    // ========== Pausable ==========

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle incoming LayerZero messages
    /// @dev Called when remote chain sends credit utilization notification (MSG_CREDIT_USED)
    function _lzReceive(
        Origin calldata origin,
        bytes32 /*guid*/,
        bytes calldata payload,
        address /*executor*/,
        bytes calldata /*extraData*/
    ) internal override whenNotPaused {
        // Verify source is a supported chain
        if (!_isSupported[origin.srcEid]) revert UnauthorizedSource(origin.srcEid);

        bytes1 msgType = MessageCodec.decodeMsgType(payload);

        if (msgType == MessageCodec.MSG_CREDIT_USED) {
            // Credit used notification from satellite (0x10)
            uint256 amount = MessageCodec.decodeAmount(payload);
            _reduceCredit(origin.srcEid, amount);
            emit CreditsReceived(origin.srcEid, amount);
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    // ========== Internal Functions ==========

    /// @notice Send the latest absolute credit allocation to a remote chain
    function _syncCreditAllocation(
        uint32 dstEid,
        uint256 newCredit,
        uint256 nativeFee,
        address refundAddress
    ) internal {
        bytes memory payload = MessageCodec.encodeCreditUpdate(newCredit);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);
        _lzSend(dstEid, payload, options, MessagingFee(nativeFee, 0), payable(refundAddress));
    }

    /// @notice Internal function to reduce credit (mark as utilized)
    /// @dev P0-7 FIX: Only increases utilized, does NOT reduce credit or totalCredits.
    ///      Credit represents allocation, utilized tracks usage within that allocation.
    /// @param eid Chain endpoint ID
    /// @param amount Amount to mark as utilized
    function _reduceCredit(uint32 eid, uint256 amount) internal {
        if (!_isSupported[eid]) revert ChainNotSupported(eid);

        ChainCredit storage cc = _chainCredits[eid];
        uint256 available = cc.credit > cc.utilized ? cc.credit - cc.utilized : 0;
        if (available < amount) revert InsufficientCredit(available, amount);

        cc.utilized += amount;
        cc.lastUpdate = block.timestamp;

        emit CreditUtilized(eid, cc.utilized);
    }

    /// @notice Override _payNative to support multiple LZ sends in single tx
    /// @dev Uses address(this).balance instead of msg.value, since msg.value is constant
    ///      across multiple _lzSend calls within rebalance()
    /// @param _nativeFee The native fee for this specific send
    /// @return nativeFee The fee amount paid
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        if (address(this).balance < _nativeFee) revert NotEnoughNative(_nativeFee);
        return _nativeFee;
    }
}
