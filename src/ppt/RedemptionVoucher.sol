// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title RedemptionVoucher
/// @author Paimon Yield Protocol
/// @notice Redemption Voucher NFT - Tradeable voucher for long-term redemptions (>7 days)
/// @dev ERC721 standard, UUPS upgradeable pattern
contract RedemptionVoucher is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using Strings for uint256;

    // =============================================================================
    // Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // =============================================================================
    // Data Structures
    // =============================================================================

    struct VoucherInfo {
        uint256 requestId;       // Associated redemption request ID
        uint256 grossAmount;     // Redemption amount (USDT, 18 decimals)
        uint256 settlementTime;  // Settlement date (UNIX timestamp)
        uint256 mintTime;        // Minting time (UNIX timestamp)
    }

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice NFT token ID counter
    uint256 private _tokenIdCounter;

    /// @notice tokenId => VoucherInfo
    mapping(uint256 => VoucherInfo) private _voucherInfo;

    /// @notice requestId => tokenId (for reverse lookup)
    mapping(uint256 => uint256) private _requestToToken;

    // =============================================================================
    // Events
    // =============================================================================

    event VoucherMinted(uint256 indexed tokenId, uint256 indexed requestId, address indexed to, uint256 grossAmount, uint256 settlementTime);
    event VoucherBurned(uint256 indexed tokenId, uint256 indexed requestId);

    // =============================================================================
    // Errors
    // =============================================================================

    error RequestAlreadyHasVoucher(uint256 requestId);
    error VoucherNotFound(uint256 tokenId);
    error InvalidRequestId();

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize function (replaces constructor in proxy pattern)
    /// @param admin Admin address
    function initialize(address admin) external initializer {
        __ERC721_init("PNGY Redemption Voucher", "PNGY-RV");
        __ERC721Enumerable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    // =============================================================================
    // UUPS Upgrade Authorization
    // =============================================================================

    /// @notice Authorize upgrade (only ADMIN can call)
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // =============================================================================
    // Minting & Burning (Only MINTER_ROLE - RedemptionManager)
    // =============================================================================

    /// @notice Mint redemption voucher NFT
    /// @param to Recipient address
    /// @param requestId Associated redemption request ID
    /// @param grossAmount Redemption amount
    /// @param settlementTime Settlement time
    /// @return tokenId Minted NFT token ID
    function mint(
        address to,
        uint256 requestId,
        uint256 grossAmount,
        uint256 settlementTime
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        if (requestId == 0) revert InvalidRequestId();
        if (_requestToToken[requestId] != 0) {
            revert RequestAlreadyHasVoucher(requestId);
        }

        tokenId = ++_tokenIdCounter;
        _safeMint(to, tokenId);

        _voucherInfo[tokenId] = VoucherInfo({
            requestId: requestId,
            grossAmount: grossAmount,
            settlementTime: settlementTime,
            mintTime: block.timestamp
        });
        _requestToToken[requestId] = tokenId;

        emit VoucherMinted(tokenId, requestId, to, grossAmount, settlementTime);
    }

    /// @notice Burn redemption voucher NFT (called at settlement)
    /// @param tokenId NFT token ID to burn
    function burn(uint256 tokenId) external onlyRole(MINTER_ROLE) {
        VoucherInfo memory info = _voucherInfo[tokenId];
        if (info.requestId == 0) revert VoucherNotFound(tokenId);

        delete _requestToToken[info.requestId];
        delete _voucherInfo[tokenId];
        _burn(tokenId);

        emit VoucherBurned(tokenId, info.requestId);
    }

    // =============================================================================
    // View Functions
    // =============================================================================

    /// @notice Get voucher information
    /// @param tokenId NFT token ID
    function voucherInfo(uint256 tokenId) external view returns (
        uint256 requestId,
        uint256 grossAmount,
        uint256 settlementTime,
        uint256 mintTime
    ) {
        VoucherInfo memory info = _voucherInfo[tokenId];
        return (info.requestId, info.grossAmount, info.settlementTime, info.mintTime);
    }

    /// @notice Get tokenId by requestId
    /// @param requestId Redemption request ID
    function requestToToken(uint256 requestId) external view returns (uint256) {
        return _requestToToken[requestId];
    }

    /// @notice Get complete voucher information by requestId
    /// @param requestId Redemption request ID
    function getVoucherByRequest(uint256 requestId) external view returns (
        uint256 tokenId,
        VoucherInfo memory info
    ) {
        tokenId = _requestToToken[requestId];
        if (tokenId != 0) {
            info = _voucherInfo[tokenId];
        }
    }

    /// @notice Check if voucher is settleable (current time >= settlement time)
    /// @param tokenId NFT token ID
    function isSettleable(uint256 tokenId) external view returns (bool) {
        VoucherInfo memory info = _voucherInfo[tokenId];
        if (info.requestId == 0) return false;
        return block.timestamp >= info.settlementTime;
    }

    /// @notice Get remaining time until settlement
    /// @param tokenId NFT token ID
    function timeUntilSettlement(uint256 tokenId) external view returns (uint256) {
        VoucherInfo memory info = _voucherInfo[tokenId];
        if (info.requestId == 0) return 0;
        if (block.timestamp >= info.settlementTime) return 0;
        return info.settlementTime - block.timestamp;
    }

    // =============================================================================
    // Token URI - On-chain SVG Metadata
    // =============================================================================

    /// @notice Return NFT metadata (on-chain SVG)
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        VoucherInfo memory info = _voucherInfo[tokenId];
        if (info.requestId == 0) revert VoucherNotFound(tokenId);

        string memory svg = _generateSVG(info);
        string memory amountStr = _formatAmount(info.grossAmount);

        string memory json = string(abi.encodePacked(
            '{"name":"PNGY Redemption Voucher #', tokenId.toString(),
            '","description":"Redeemable for ', amountStr, ' USDT. Settlement timestamp: ',
            info.settlementTime.toString(), '",',
            '"attributes":[',
                '{"trait_type":"Request ID","value":"', info.requestId.toString(), '"},',
                '{"trait_type":"Amount (USDT)","value":"', amountStr, '"},',
                '{"trait_type":"Settlement Time","value":"', info.settlementTime.toString(), '"},',
                '{"trait_type":"Mint Time","value":"', info.mintTime.toString(), '"}',
            '],',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '"}'
        ));

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    /// @notice Generate SVG image
    function _generateSVG(VoucherInfo memory info) internal pure returns (string memory) {
        string memory amountStr = _formatAmount(info.grossAmount);

        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="250" viewBox="0 0 400 250">',
            '<defs><linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" style="stop-color:#1a1a2e"/>',
            '<stop offset="100%" style="stop-color:#16213e"/>',
            '</linearGradient></defs>',
            '<rect width="400" height="250" fill="url(#bg)" rx="15"/>',
            '<text x="200" y="35" fill="#fff" font-size="18" text-anchor="middle" font-family="Arial" font-weight="bold">PNGY Redemption Voucher</text>',
            '<line x1="40" y1="55" x2="360" y2="55" stroke="#4ade80" stroke-width="2"/>',
            '<text x="200" y="110" fill="#4ade80" font-size="42" text-anchor="middle" font-family="Arial" font-weight="bold">', amountStr, '</text>',
            '<text x="200" y="140" fill="#9ca3af" font-size="16" text-anchor="middle" font-family="Arial">USDT</text>',
            '<text x="40" y="190" fill="#6b7280" font-size="12" font-family="Arial">Request #', info.requestId.toString(), '</text>',
            '<text x="360" y="190" fill="#6b7280" font-size="12" text-anchor="end" font-family="Arial">Settlement: ', info.settlementTime.toString(), '</text>',
            '<rect x="40" y="210" width="320" height="25" fill="#0f172a" rx="5"/>',
            '<text x="200" y="227" fill="#94a3b8" font-size="10" text-anchor="middle" font-family="Arial">Transferable - Present to redeem USDT</text>',
            '</svg>'
        ));
    }

    /// @notice Format amount (18 decimals -> integer string)
    function _formatAmount(uint256 amount) internal pure returns (string memory) {
        return (amount / 1e18).toString();
    }

    // =============================================================================
    // Required Overrides
    // =============================================================================

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) returns (address) {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Upgradeable, ERC721EnumerableUpgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
