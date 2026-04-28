// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/V3Vault.sol";
import "../src/transformers/V3Utils.sol";

contract ConfigureV3Utils is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    function run() external {
        require(block.chainid == BASE_CHAIN_ID, "ConfigureV3Utils: wrong chain");

        address v3UtilsAddress = vm.envAddress("V3_UTILS");
        address vaultAddress = vm.envAddress("VAULT");

        _requireCode(v3UtilsAddress, "ConfigureV3Utils: V3Utils missing code");
        _requireCode(vaultAddress, "ConfigureV3Utils: vault missing code");

        V3Utils v3Utils = V3Utils(payable(v3UtilsAddress));
        V3Vault vault = V3Vault(vaultAddress);

        require(vault.transformerAllowList(v3UtilsAddress), "ConfigureV3Utils: V3Utils not allowed by vault");

        address owner = v3Utils.owner();
        bytes memory setVaultCalldata = abi.encodeWithSignature("setVault(address)", vaultAddress);

        console2.log("V3_UTILS", v3UtilsAddress);
        console2.log("V3_UTILS_OWNER", owner);
        console2.log("VAULT", vaultAddress);
        console2.log("V3_UTILS_VAULT_CONFIGURED", v3Utils.vaults(vaultAddress));
        console2.log("SET_VAULT_CALLDATA");
        console2.logBytes(setVaultCalldata);

        if (v3Utils.vaults(vaultAddress)) {
            return;
        }

        if (!_envBoolOrFalse("BROADCAST_V3_UTILS_CONFIG")) {
            return;
        }

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        require(signer == owner, "ConfigureV3Utils: signer is not V3Utils owner");

        vm.startBroadcast(signer);
        v3Utils.setVault(vaultAddress);
        vm.stopBroadcast();

        console2.log("V3_UTILS_VAULT_CONFIGURED", v3Utils.vaults(vaultAddress));
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _envBoolOrFalse(string memory key) internal returns (bool value) {
        try vm.envBool(key) returns (bool configuredValue) {
            value = configuredValue;
        } catch {
            value = false;
        }
    }
}
