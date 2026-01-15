// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/V3Vault.sol";
import "../src/transformers/ConstantLeverageTransformer.sol";

/// @title Deploy ConstantLeverageTransformer to existing vault
/// @notice Deploys and registers ConstantLeverageTransformer with an existing V3Vault
/// @dev Set environment variables before running:
///      - VAULT: Address of existing V3Vault
///      - OPERATOR: Address of operator bot (optional, can be set later)
///      - WITHDRAWER: Address for fee withdrawal (optional, can be set later)
contract DeployConstantLeverageTransformer is Script {
    // Arbitrum addresses
    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;
    address constant UNIVERSAL_ROUTER = 0x5E325eDA8064b456f4781070C0738d849c824258;

    function run() external {
        // Get vault address from environment
        address vaultAddress = vm.envAddress("VAULT");
        require(vaultAddress != address(0), "VAULT env var required");

        // Optional: get operator and withdrawer from environment (default to address(0))
        address operator = _tryEnvAddress("OPERATOR");
        address withdrawer = _tryEnvAddress("WITHDRAWER");

        vm.startBroadcast();

        // Deploy ConstantLeverageTransformer
        ConstantLeverageTransformer transformer = new ConstantLeverageTransformer(
            NPM,
            operator,
            withdrawer,
            60,  // TWAPSeconds
            100, // maxTWAPTickDifference (1%)
            UNIVERSAL_ROUTER,
            EX0x
        );

        // Register with vault
        transformer.setVault(vaultAddress);

        // Note: vault.setTransformer() must be called by vault owner separately
        // This script only deploys the transformer and sets its vault reference

        vm.stopBroadcast();

        // Log deployed address
        console.log("ConstantLeverageTransformer deployed at:", address(transformer));
        console.log("Operator:", operator);
        console.log("Withdrawer:", withdrawer);
        console.log("");
        console.log("Next steps:");
        console.log("1. Vault owner must call: vault.setTransformer(", address(transformer), ", true)");
        if (operator == address(0)) {
            console.log("2. Set operator: transformer.setOperator(<operator_address>, true)");
        }
        if (withdrawer == address(0)) {
            console.log("3. Set withdrawer: transformer.setWithdrawer(<withdrawer_address>)");
        }
    }

    function _tryEnvAddress(string memory name) internal returns (address) {
        try vm.envAddress(name) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }
}
