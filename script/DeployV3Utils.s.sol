// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/transformers/V3Utils.sol";

contract DeployV3Utils is Script {
    function run() external {
        
        // Hardcoded dependency addresses for Unichain deployment.
        address nonfungiblePositionManager = 0x943e6e07a7E8E791dAFC44083e54041D743C46E9;
        address zeroxRouter = address(0); // Not using 0x router functionality.
        address universalRouter = 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3;
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        vm.startBroadcast();

        // Deploy V3Utils with the hardcoded constructor parameters.
        V3Utils v3utils = new V3Utils(
            INonfungiblePositionManager(nonfungiblePositionManager),
            zeroxRouter,
            universalRouter,
            permit2
        );

        console.log("V3Utils deployed at:", address(v3utils));

        vm.stopBroadcast();
    }
} 