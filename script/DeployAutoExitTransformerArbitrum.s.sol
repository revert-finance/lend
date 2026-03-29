// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/V3Vault.sol";
import "../src/transformers/AutoExitTransformer.sol";

contract DeployAutoExitTransformerArbitrum is Script {
    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;
    address constant UNIVERSAL_ROUTER = 0x5E325eDA8064b456f4781070C0738d849c824258;

    // Existing vault on Arbitrum - UPDATE THIS ADDRESS before deployment
    address constant VAULT = address(0);

    // Operator and withdrawer addresses - UPDATE THESE before deployment
    address constant OPERATOR = address(0);
    address constant WITHDRAWER = address(0);

    function run() external {
        vm.startBroadcast();

        // Deploy AutoExitTransformer
        // Constructor: _npm, _operator, _withdrawer, _TWAPSeconds, _maxTWAPTickDifference, _universalRouter, _zeroxAllowanceHolder
        AutoExitTransformer autoExitTransformer = new AutoExitTransformer(
            NPM,
            OPERATOR,
            WITHDRAWER,
            60, // TWAPSeconds
            100, // maxTWAPTickDifference
            UNIVERSAL_ROUTER,
            EX0x
        );

        // Configure transformer with vault
        autoExitTransformer.setVault(VAULT);

        // Note: The vault owner needs to call vault.setTransformer(address(autoExitTransformer), true)
        // to whitelist this transformer

        console.log("AutoExitTransformer deployed at:", address(autoExitTransformer));
        console.log("Remember to call vault.setTransformer(", address(autoExitTransformer), ", true) from vault owner");

        vm.stopBroadcast();
    }
}
