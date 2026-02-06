// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapter} from "../ppt/IPPTContracts.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
library OracleTyping{
    
    enum PaimonOracle{
        chainlink,
        USDT
    }

    struct OracleType{
        PaimonOracle typeName;
        address feed;
        uint8 decimals;
    }
    struct CatchPrice{
        uint256 price;
        uint256 updatedAt;
    }
}



contract PaimonOracleAdapter is
    Initializable,
    IOracleAdapter,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    mapping(address => OracleTyping.OracleType) public OracleRecord;


    event UpdateOracleFeed(address indexed asset, OracleTyping.PaimonOracle oracleType, address feed,  uint8 decimals);
    event RemoveOracleFeed(address indexed asset);
    event ValueInvalid(address indexed asset,int256 value);
    event OracleAdapterUpgraded(address indexed newImplementation, uint256 timestamp, uint256 blockNumber);
    error ZeroAddress();
    error OracleNotFound();
    error InvalidValue(address asset, int256 value);
 
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address adminsig_, address timerlock_) external initializer {
        if (adminsig_ == address(0) || timerlock_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, adminsig_);
        _grantRole(ADMIN_ROLE, adminsig_);
        _grantRole(UPGRADER_ROLE, timerlock_);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit OracleAdapterUpgraded(newImplementation, block.timestamp, block.number);
    }

    function addOrUpdateFeed(address asset,OracleTyping.PaimonOracle oralceType,address feed) external onlyRole(ADMIN_ROLE){
        if(asset==address(0)||feed==address(0)) revert ZeroAddress();

        uint8 decimals;
        // USDT type: fixed 1:1 pricing, no need to call feed.decimals()
        if (oralceType == OracleTyping.PaimonOracle.USDT) {
            decimals = 18; // Fixed 18 decimals
        } else {
            AggregatorV3Interface v3 = AggregatorV3Interface(feed);
            decimals = v3.decimals();
        }

        OracleRecord[asset]=OracleTyping.OracleType({
            typeName: oralceType,
            feed:feed,
            decimals:decimals
        });
        emit UpdateOracleFeed(asset,oralceType,feed,decimals);
    }

    function getOracleRecord(address asset) external view onlyRole(ADMIN_ROLE) returns (OracleTyping.OracleType memory) {
        return OracleRecord[asset];
    }



    function removeFeed(address asset) external onlyRole(ADMIN_ROLE) {
        if (OracleRecord[asset].feed == address(0)) revert OracleNotFound();
        delete OracleRecord[asset];
        emit RemoveOracleFeed(asset);
    }

    
    function getPrice(address asset) external view override returns (uint256 price) {
        if (OracleRecord[asset].feed == address(0)) revert OracleNotFound();
        OracleTyping.OracleType memory oracleRecord = OracleRecord[asset];

        // USDT type: returns fixed 1e18 (1:1 pricing, for stablecoin wrappers like aUSDT)
        if (oracleRecord.typeName == OracleTyping.PaimonOracle.USDT) {
            return 1e18;
        }

        if (oracleRecord.typeName==OracleTyping.PaimonOracle.chainlink) {
            AggregatorV3Interface v3 = AggregatorV3Interface(oracleRecord.feed);
            (, int256 answer, , , ) = v3.latestRoundData();
            uint8 decimals = v3.decimals();
            return _priceFormat(asset, answer, decimals);
        }

        // If not chainlink or USDT type, revert
        revert OracleNotFound();
    }

    function getPriceWithRoundId(address asset,uint80 roundId) external view returns (uint256 price) {
        if (OracleRecord[asset].feed == address(0)) revert OracleNotFound();
        OracleTyping.OracleType memory oracleRecord = OracleRecord[asset];

        // USDT type: returns fixed 1e18 (1:1 pricing, ignores roundId)
        if (oracleRecord.typeName == OracleTyping.PaimonOracle.USDT) {
            return 1e18;
        }

        if (oracleRecord.typeName==OracleTyping.PaimonOracle.chainlink) {
            AggregatorV3Interface v3 = AggregatorV3Interface(oracleRecord.feed);
            (, int256 answer, , , ) = v3.getRoundData(roundId);
            uint8 decimals = v3.decimals();

            return _priceFormat(asset, answer, decimals);
        }

        revert OracleNotFound();
    }

    function getPriceWithAllInfo(address asset,uint80 roundId) external view returns (uint80 _roundId,int256 price,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound) {
        if (OracleRecord[asset].feed == address(0)) revert OracleNotFound();
        OracleTyping.OracleType memory oracleRecord = OracleRecord[asset];

        // USDT type: returns fixed values (1e18 price, current timestamp)
        if (oracleRecord.typeName == OracleTyping.PaimonOracle.USDT) {
            return (0, int256(1e18), block.timestamp, block.timestamp, 0);
        }

        if (oracleRecord.typeName==OracleTyping.PaimonOracle.chainlink) {
            AggregatorV3Interface v3 = AggregatorV3Interface(oracleRecord.feed);
            if(roundId==0){
                (_roundId,  price,  startedAt,  updatedAt,  answeredInRound) = v3.latestRoundData();
            } else {
                (_roundId,  price,  startedAt,  updatedAt,  answeredInRound) = v3.getRoundData(roundId);
            }
            return (_roundId, price, startedAt, updatedAt, answeredInRound);
        }

        revert OracleNotFound();
    }

    /**
     * @notice Convert price to 18 decimal format
     * @param asset Asset address
     * @param price Original price
     * @param decimals Original decimal places
     * @return Price converted to 18 decimals
     * @dev If decimals < 18, multiply by 10^(18-decimals)
     *      If decimals > 18, divide by 10^(decimals-18) (may lose precision)
     *      If price is 0, revert
     */
    function _priceFormat(address asset, int256 price, uint8 decimals) internal pure returns (uint256) {
        // N36 Fix: reject zero and negative prices to prevent unsafe int256 -> uint256 cast
        if(price <= 0){
            revert InvalidValue(asset, price);
        }
         uint256 rprice = uint256(price);
        if (decimals == 18) {
            return rprice;
        } else if (decimals < 18) {
            // Multiply by 10^(18-decimals), note potential overflow
            return rprice * (10 ** (18 - decimals));
        } else {
            // Divide by 10^(decimals-18), note precision loss
            return rprice / (10 ** (decimals - 18));
        }
    }

}