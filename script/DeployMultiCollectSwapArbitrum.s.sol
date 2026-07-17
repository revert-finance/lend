// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/transformers/MultiCollectSwap.sol";

contract DeployMultiCollectSwapArbitrum is Script {
    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant UNIVERSAL_ROUTER = 0x5E325eDA8064b456f4781070C0738d849c824258;
    address constant EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Existing vault address on Arbitrum (update this to the actual deployed vault address)
    address constant VAULT = address(0); // TODO: Set to actual vault address before deployment

    function run() external {
        vm.startBroadcast();

        // Deploy MultiCollectSwap
        MultiCollectSwap multiCollectSwap = new MultiCollectSwap(NPM, UNIVERSAL_ROUTER, EX0x);

        // Configure vault integration (only if VAULT is set)
        if (VAULT != address(0)) {
            multiCollectSwap.setVault(VAULT);
            // Note: vault.setTransformer(address(multiCollectSwap), true) must be called
            // by the vault owner separately
        }

        console.log("MultiCollectSwap deployed at:", address(multiCollectSwap));

        vm.stopBroadcast();
    }
}
