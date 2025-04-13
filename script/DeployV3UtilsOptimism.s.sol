// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/transformers/V3Utils.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import { Interface, hexlify } from "ethers";
import crypto from "crypto";

contract DeployV3UtilsOptimism is Script {
    function run() external {
        // Hardcoded Optimism mainnet addresses
        address nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88; // Optimism NPM
        address universalRouter = 0x851116D9223fabED8E56C0E6b8Ad0c31d98B3507; // Optimism Universal Router
        address zeroxAllowanceHolder = 0x0000000000001fF3684f28c67538d4D072C22734; // Optimism 0x Proxy
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Same Permit2 address across chains

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy V3Utils
        V3Utils v3Utils = new V3Utils(
            INonfungiblePositionManager(nonfungiblePositionManager),
            universalRouter,
            zeroxAllowanceHolder,
            permit2
        );

        // Log deployment information
        console.log("V3Utils deployed to:", address(v3Utils));
        console.log("Owner:", v3Utils.owner());

        // Define the transformer address and active status
        address transformerAddress = address(v3Utils);
        bool active = true;

        // Create an interface for the V3Vault contract
        Interface iface = new Interface([
            "function setTransformer(address transformer, bool active)"
        ]);

        // Encode the function call
        bytes memory data = iface.encodeFunctionData("setTransformer", [transformerAddress, active]);

        // Generate a random salt
        bytes memory salt = crypto.randomBytes(32);

        // Output the results
        console.log("Encoded data:", data);
        console.log("Generated salt:", hexlify(salt));

        vm.stopBroadcast();
    }
} 