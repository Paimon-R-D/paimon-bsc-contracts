// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BSC Mainnet 地址配置
library BSCMainnet {
    // ========== 管理地址 ==========
    address public constant ADMIN_SIG = 0xDc814FdF8F5b969C29257e434C8205678a03f810;

    // ========== Aave V3 核心地址 ==========
    address public constant AAVE_POOL = 0x6807dc923806fE8Fd134338EABCA509979a7e0cB;
    address public constant AAVE_ORACLE = 0x39bc1bfDa2130d6Bb6DBEfd366939b4c7aa7C697;
    address public constant AAVE_POOL_DATA_PROVIDER = 0xc90Df74A7c16245c5F5C5870327Ceb38Fe5d5328;

    // ========== Token 地址 ==========
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant aUSDT = 0xa9251ca9DE909CB71783723713B21E4233fbf1B1;

    // ========== HYD Feed ==========
    address public constant HYD_FEED = address(0xd67fEb95c60faB0D79Edb86b795DbEbb9FEF3924);

    // ========== Paimon Deployed Addresses ==========
    address public constant PAIMON_ORACLE_ADAPTER = address(0x6b752F021749D8D82CE6262ADAAf093CFaEa3034);
    address public constant PAIMON_TIMELOCK = address(0x2573d3c585fD4821353Def01E2fb69f3385f7A59);
    address public constant PAIMON_PPT = address(0x8505c32631034A7cE8800239c08547e0434EdaD9);
    address public constant PAIMON_ASSET_CONTROLLER = address(0x6F5170956132588E9b2844478f1fF1B387573A3D);
    address public constant PAIMON_REDEMPTION_MANAGER = address(0xd614a6fe8C35aC9af4F59cd14849877179cDCdB9);
    address public constant PAIMON_REDEMPTION_VOUCHER = address(0x73F42b0D657785fE844e3BF486Fe1e15fFE13514);
    address public constant PAIMON_AAVE_ADAPTER = address(0x33F20C1cE8E13933584cB2f9D6bA16b88f11A582);

    // ========== HYD Deployed Addresses ==========
    address public constant PAIMON_HYD = address(0x0CE9D734aAE1B7795Ab66c0306eeaE1a4B97705a);
    address public constant PAIMON_HYD_GATEWAY = address(0x9C550C95b16bF0F4320A26aAe6f783e224603401);

    // ========== Points Deployed Addresses ==========
    address public constant PAIMON_STAKING_MODULE = address(0xBac2f856FCbac35112bfbd187B6939e80Da66344);
    address public constant PAIMON_POINTS_HUB = address(0xDb3cA4f0068C2E8c95995A2Ed0F2E3858465bea3);
    // NFT
    address public constant RWA_BOND_NFT=address(0x55e1944C0fa2aB059eD11F395D58Ed170d39e4c9);
    address public constant PAIMON_TREASURY=address(0x73292fC557f8AB96670C79D0734969CAF004F4aD);
}
