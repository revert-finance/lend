// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/transformers/V3Utils.sol";

/// @notice Standalone Aero utilities. No lending vault is deployed or authorized.
contract DeployAeroV3UtilsMultichain is Script {
    address internal constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address internal constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    struct Config {
        address factory;
        address weth;
        address router;
    }

    function config(uint256 chainId) public pure returns (Config memory) {
        if (chainId == 1) {
            return Config(
                0xF4Fd2E6c5B60c5b365cd1B96DD6245E6D60414c2,
                0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af
            );
        }
        if (chainId == 4663) {
            return Config(
                0xc63d7338c178e805c544B8f897066bD3BBcBE136,
                0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73,
                0x8876789976dEcBfCbBbe364623C63652db8C0904
            );
        }
        revert("Unsupported chain");
    }

    function run() external returns (V3Utils deployed) {
        require(block.chainid == vm.envUint("AERO_CHAIN_ID"), "Wrong chain");
        Config memory cfg = config(block.chainid);
        address deployer = vm.envAddress("AERO_DEPLOYER");
        address finalOwner = vm.envAddress("AERO_V3UTILS_OWNER");
        require(deployer != address(0) && finalOwner != address(0), "Zero owner/deployer");
        require(NPM.code.length != 0 && cfg.factory.code.length != 0, "Missing Aero deployment");
        require(cfg.weth.code.length != 0 && cfg.router.code.length != 0, "Missing WETH/router");
        require(ALLOWANCE_HOLDER.code.length != 0, "Missing allowance holder");
        INonfungiblePositionManager npm = INonfungiblePositionManager(NPM);
        require(npm.factory() == cfg.factory, "NPM factory mismatch");
        require(npm.WETH9() == cfg.weth, "NPM WETH mismatch");

        vm.startBroadcast(deployer);
        deployed = new V3Utils(npm, cfg.router, ALLOWANCE_HOLDER);
        if (finalOwner != deployer) deployed.transferOwnership(finalOwner);
        vm.stopBroadcast();

        require(deployed.owner() == deployer, "Unexpected initial owner");
        require(deployed.pendingOwner() == (finalOwner == deployer ? address(0) : finalOwner), "Wrong pending owner");
        require(deployed.factory() == cfg.factory && address(deployed.weth()) == cfg.weth, "Wrong bindings");
        console2.log("CHAIN_ID", block.chainid);
        console2.log("V3UTILS", address(deployed));
        console2.log("OWNER", deployed.owner());
        console2.log("PENDING_OWNER", deployed.pendingOwner());
        console2.log("NPM", NPM);
        console2.log("FACTORY", cfg.factory);
        console2.log("WETH", cfg.weth);
        console2.log("UNIVERSAL_ROUTER", cfg.router);
        console2.log("ALLOWANCE_HOLDER", ALLOWANCE_HOLDER);
    }
}
