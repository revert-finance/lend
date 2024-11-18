// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/transformers/V3Utils.sol";
import "../src/interfaces/velodrome/IVelodromePositionManager.sol";

contract DeployV3UtilsOptimism is Script {
    IVelodromePositionManager constant NPM = IVelodromePositionManager(0x416b433906b1B72FA758e166e239c43d68dC6F29);
    address constant EX0x = 0xDEF1ABE32c034e558Cdd535791643C58a13aCC10;
    address constant UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;

    function run() external {
        // Load environment variables
        
        // Add these debug lines
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        console.log("Deploying on chain ID:", chainId);
        
        vm.startBroadcast();

        V3Utils v3Utils = new V3Utils(NPM, EX0x, UNIVERSAL_ROUTER);

        console.log("V3Utils deployed to:", address(v3Utils));

        vm.stopBroadcast();
    }
}
