// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";


contract DeployMTK is Script {
    
    uint256 public constant TIMELOCK_DELAY = 1 hours;

    function run() external {
       
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address gnosisSafe = vm.envAddress("GNOSIS_SAFE");

        require(gnosisSafe != address(0), "GNOSIS_SAFE not set in .env");

        console.log("Deploying MTK Token System...");
        console.log("Gnosis Safe:", gnosisSafe);
        console.log("Timelock Delay:", TIMELOCK_DELAY);

        vm.startBroadcast(deployerPrivateKey);

  
        address[] memory proposers = new address[](1);
        proposers[0] = gnosisSafe;

        address[] memory executors = new address[](1);
        executors[0] = gnosisSafe;

        TimelockController timelock = new TimelockController(
            TIMELOCK_DELAY,
            proposers,
            executors,
            address(0) 
        );
        console.log("TimelockController deployed:", address(timelock));
        vm.stopBroadcast();
    }
}