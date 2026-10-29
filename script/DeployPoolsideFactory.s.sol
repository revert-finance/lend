// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/poolside/PoolsideFactory.sol";

/// @notice Replace only the Poolside factory against the verified 2026-10-29 Base suite.
contract DeployPoolsideFactory is Script {
    V3Utils internal constant UTILS = V3Utils(payable(0xF3B5c0689df879Db47Fd23590700910e7a99A068));
    V3Vault internal constant VAULT = V3Vault(0x39125A0476D44C9EEC1F4206E9e8B1e88b4Aa730);
    AutoRangeAndCompound internal constant AUTOMATION =
        AutoRangeAndCompound(payable(0x5c94a69fFDC3Fcb2c3d6e08Ce033297Fb92aE800));
    AutoExit internal constant EXIT = AutoExit(payable(0x9b23ba84C0B33c608db6a1c34Fc37BaA1F1A2C65));

    function run() external returns (PoolsideFactory deployed) {
        address deployer = vm.envAddress("AERO_DEPLOYER");
        require(block.chainid == 8453, "Base only");
        // Check before the first broadcast: after Safe acceptance, authorization must be done by the Safe.
        require(EXIT.owner() == deployer, "AutoExit owner must authorize factory");
        require(AUTOMATION.simpleRewardX64() == uint64((uint256(1) << 64) / 10), "Simple fee must be 10%");
        vm.startBroadcast(deployer);
        deployed = new PoolsideFactory(UTILS, VAULT, AUTOMATION, EXIT);
        EXIT.setOperator(address(deployed), true);
        vm.stopBroadcast();
        require(EXIT.operators(address(deployed)), "factory not authorized");
        console2.log("POOLSIDE_FACTORY", address(deployed));
        console2.log("AUTO_EXIT", address(EXIT));
        console2.log("FACTORY_AUTHORIZED", EXIT.operators(address(deployed)));
    }
}
