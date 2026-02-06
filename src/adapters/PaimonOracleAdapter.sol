// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapter} from "../ppt/IPPTContracts.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
library OracleTyping{
    
    enum PaimonOracle{
        chainlink,
        USDT,
        pyth
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
    /// @dev N35 Fix: appended after OracleRecord for UUPS storage layout safety
    uint256 public defaultStaleness;
    mapping(address => uint256) public maxStaleness;
    /// @dev Pyth oracle contract address (global, set by admin)
    address public pythOracle;
    /// @dev Per-asset Pyth price feed IDs
    mapping(address => bytes32) public pythPriceIds;


    event UpdateOracleFeed(address indexed asset, OracleTyping.PaimonOracle oracleType, address feed,  uint8 decimals);
    event RemoveOracleFeed(address indexed asset);
    event ValueInvalid(address indexed asset,int256 value);
    event OracleAdapterUpgraded(address indexed newImplementation, uint256 timestamp, uint256 blockNumber);
    event StalePriceDetected(address indexed asset, uint256 updatedAt, uint256 staleness);
    event MaxStalenessUpdated(address indexed asset, uint256 staleness);
    event DefaultStalenessUpdated(uint256 staleness);
    event PythOracleUpdated(address indexed pythOracle);
    event PythFeedUpdated(address indexed asset, bytes32 priceId);
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

    function addOrUpdatePythFeed(address asset, bytes32 priceId) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (pythOracle == address(0)) revert ZeroAddress();

        pythPriceIds[asset] = priceId;
        OracleRecord[asset] = OracleTyping.OracleType({
            typeName: OracleTyping.PaimonOracle.pyth,
            feed: pythOracle,
            decimals: 18
        });
        emit PythFeedUpdated(asset, priceId);
    }

    function getOracleRecord(address asset) external view onlyRole(ADMIN_ROLE) returns (OracleTyping.OracleType memory) {
        return OracleRecord[asset];
    }



    function setDefaultStaleness(uint256 staleness) external onlyRole(ADMIN_ROLE) {
        defaultStaleness = staleness;
        emit DefaultStalenessUpdated(staleness);
    }

    function setMaxStaleness(address asset, uint256 staleness) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        maxStaleness[asset] = staleness;
        emit MaxStalenessUpdated(asset, staleness);
    }

    function setPythOracle(address _pythOracle) external onlyRole(ADMIN_ROLE) {
        if (_pythOracle == address(0)) revert ZeroAddress();
        pythOracle = _pythOracle;
        emit PythOracleUpdated(_pythOracle);
    }

    /// @notice N35 Fix: off-chain monitoring calls this to detect and emit stale price events.
    /// @return isStale true if the price data exceeds the staleness threshold
    function checkPriceFreshness(address asset) external returns (bool isStale) {
        OracleTyping.OracleType memory oracleRecord = OracleRecord[asset];
        if (oracleRecord.feed == address(0)) revert OracleNotFound();

        uint256 _default = defaultStaleness > 0 ? defaultStaleness : 1 days;
        uint256 staleness = maxStaleness[asset] > 0 ? maxStaleness[asset] : _default;

        if (oracleRecord.typeName == OracleTyping.PaimonOracle.chainlink) {
            AggregatorV3Interface v3 = AggregatorV3Interface(oracleRecord.feed);
            (uint80 roundId, , , uint256 updatedAt, uint80 answeredInRound) = v3.latestRoundData();
            if (updatedAt == 0 || block.timestamp - updatedAt > staleness || answeredInRound < roundId) {
                emit StalePriceDetected(asset, updatedAt, staleness);
                return true;
            }
        } else if (oracleRecord.typeName == OracleTyping.PaimonOracle.pyth) {
            IPyth pyth = IPyth(oracleRecord.feed);
            PythStructs.Price memory p = pyth.getPriceUnsafe(pythPriceIds[asset]);
            if (p.publishTime == 0 || block.timestamp - p.publishTime > staleness) {
                emit StalePriceDetected(asset, p.publishTime, staleness);
                return true;
            }
        }
        return false;
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

        if (oracleRecord.typeName == OracleTyping.PaimonOracle.pyth) {
            IPyth pyth = IPyth(oracleRecord.feed);
            PythStructs.Price memory p = pyth.getPriceUnsafe(pythPriceIds[asset]);
            return _pythTo18Decimals(asset, p.price, p.expo);
        }

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

        if (oracleRecord.typeName == OracleTyping.PaimonOracle.pyth) {
            IPyth pyth = IPyth(oracleRecord.feed);
            PythStructs.Price memory p = pyth.getPriceUnsafe(pythPriceIds[asset]);
            return _pythTo18Decimals(asset, p.price, p.expo);
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

        if (oracleRecord.typeName == OracleTyping.PaimonOracle.pyth) {
            IPyth pyth = IPyth(oracleRecord.feed);
            PythStructs.Price memory p = pyth.getPriceUnsafe(pythPriceIds[asset]);
            return (0, int256(int64(p.price)), p.publishTime, p.publishTime, 0);
        }

        revert OracleNotFound();
    }



    function _abs(int32 x) internal pure returns (uint32) {
        return x < 0 ? uint32(-x) : uint32(x);
    }

    /// @dev Convert Pyth price to 18-decimal uint256. real_price = price * 10^expo
    function _pythTo18Decimals(address asset, int64 price, int32 expo) internal pure returns (uint256) {
        if (price <= 0) revert InvalidValue(asset, int256(price));
        uint256 uPrice = uint256(uint64(price));
        if (expo >= 0) {
            // expo positive: multiply by 10^(18 + expo)
            return uPrice * (10 ** (18 + _abs(expo)));
        } else {
            uint32 absExpo = _abs(expo);
            if (absExpo <= 18) {
                return uPrice * (10 ** (18 - absExpo));
            } else {
                return uPrice / (10 ** (absExpo - 18));
            }
        }
    }

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