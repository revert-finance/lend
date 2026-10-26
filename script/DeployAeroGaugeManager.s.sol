// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/GaugeManager.sol";
import "../src/interfaces/ICompoundRewardSource.sol";

interface ICompoundModeSourceSetup {
    function nonfungiblePositionManager() external view returns (address);
}

interface IAeroVaultSetup {
    function owner() external view returns (address);
    function nonfungiblePositionManager() external view returns (address);
    function gaugeManager() external view returns (address);
    function setGaugeManager(address manager) external;
}

/// @notice Deploys and wires the leaf-receipt or synchronous root-AERO gauge adapter into a fresh, separately prepared vault.
/// @dev No launch addresses are assumed. See docs/aero-migration.md for inputs and validation limits.
contract DeployAeroGaugeManager is Script {
    struct Config {
        uint256 chainId;
        address deployer;
        address npm;
        address factory;
        address receiptToken; // Historical config name: delivered reward token (receipts on leaf, AERO on root).
        address vault;
        address owner;
        address withdrawer;
        address router;
        address allowanceHolder;
        address[] pools;
        address[] gauges;
        address[] rewardBases;
        address[] rewardPools;
        address compoundModeSource; // AutoRangeAndCompound that answers each position's compound mode rate; optional
    }

    function run() public returns (GaugeManager manager) {
        Config memory c = _loadConfig();
        _validate(c);
        vm.startBroadcast(c.deployer);
        manager = new GaugeManager(
            INonfungiblePositionManager(c.npm), IERC20(c.receiptToken), IVault(c.vault), c.router, c.allowanceHolder
        );
        manager.setWithdrawer(c.withdrawer);
        for (uint256 i; i < c.pools.length; ++i) {
            manager.setGauge(c.pools[i], c.gauges[i]);
        }
        for (uint256 i; i < c.rewardBases.length; ++i) {
            manager.setRewardBasePool(c.rewardBases[i], c.rewardPools[i]);
        }
        if (c.compoundModeSource != address(0)) manager.setCompoundModeSource(c.compoundModeSource);
        IAeroVaultSetup(c.vault).setGaugeManager(address(manager));
        if (c.owner != c.deployer) manager.transferOwnership(c.owner);
        vm.stopBroadcast();
        require(IAeroVaultSetup(c.vault).gaugeManager() == address(manager), "vault binding failed");
        require(address(manager.vault()) == c.vault, "manager binding failed");
        console2.log("AERO_GAUGE_MANAGER", address(manager));
        console2.log("REWARD_TOKEN", c.receiptToken);
        console2.log("VAULT", c.vault);
        console2.log("OWNER", manager.owner());
        console2.log("PENDING_OWNER", manager.pendingOwner());
        console2.log("WITHDRAWER", manager.withdrawer());
        console2.log("COMPOUND_MODE_SOURCE", manager.compoundModeSource());
    }

    function _loadConfig() internal virtual returns (Config memory c) {
        c.chainId = vm.envUint("AERO_CHAIN_ID");
        c.deployer = vm.envAddress("AERO_DEPLOYER");
        c.npm = vm.envAddress("AERO_NPM");
        c.factory = vm.envAddress("AERO_FACTORY");
        c.receiptToken = vm.envAddress("AERO_RECEIPT_TOKEN");
        c.vault = vm.envAddress("AERO_NEW_VAULT");
        c.owner = vm.envAddress("AERO_OWNER");
        c.withdrawer = vm.envAddress("AERO_WITHDRAWER");
        c.router = vm.envAddress("AERO_ROUTER");
        c.allowanceHolder = vm.envAddress("AERO_ALLOWANCE_HOLDER");
        c.pools = vm.envAddress("AERO_POOLS", ",");
        c.gauges = vm.envAddress("AERO_GAUGES", ",");
        c.rewardBases = vm.envAddress("AERO_REWARD_BASES", ",");
        c.rewardPools = vm.envAddress("AERO_REWARD_POOLS", ",");
        // optional: the AutoRangeAndCompound deployment that answers each position's compound mode rate. Only an
        // unset or empty variable means "none"; a present but malformed value aborts the deployment (envAddress).
        try vm.envString("AERO_COMPOUND_MODE_SOURCE") returns (string memory raw) {
            if (bytes(raw).length != 0) c.compoundModeSource = vm.envAddress("AERO_COMPOUND_MODE_SOURCE");
        } catch {}
    }

    function _validate(Config memory c) internal view {
        require(block.chainid == c.chainId, "wrong chain");
        require(c.deployer != address(0) && c.owner != address(0) && c.withdrawer != address(0), "zero role");
        require(c.npm.code.length != 0 && c.factory.code.length != 0, "missing NPM/factory");
        require(c.receiptToken.code.length != 0 && c.vault.code.length != 0, "missing token/vault");
        require(c.router == address(0) || c.router.code.length != 0, "missing router");
        require(c.allowanceHolder == address(0) || c.allowanceHolder.code.length != 0, "missing allowance holder");
        if (c.compoundModeSource != address(0)) {
            require(c.compoundModeSource.code.length != 0, "missing compound mode source");
            // the source prices this vault's positions: it must manage the same NPM and answer the rate interface
            require(
                ICompoundModeSourceSetup(c.compoundModeSource).nonfungiblePositionManager() == c.npm,
                "compound mode source NPM mismatch"
            );
            ICompoundRewardSource(c.compoundModeSource).compoundRewardX64(0);
        }
        require(INonfungiblePositionManager(c.npm).factory() == c.factory, "NPM factory mismatch");
        require(IAeroVaultSetup(c.vault).nonfungiblePositionManager() == c.npm, "vault NPM mismatch");
        require(IAeroVaultSetup(c.vault).gaugeManager() == address(0), "vault already bound");
        require(IAeroVaultSetup(c.vault).owner() == c.deployer, "deployer must own fresh vault");
        require(c.pools.length != 0 && c.pools.length == c.gauges.length, "invalid gauge lists");
        require(c.rewardBases.length == c.rewardPools.length, "invalid reward routes");
        // Validate the same settlement bindings as setGauge before broadcasting any deployment transaction.
        address rootHandler;
        for (uint256 i; i < c.gauges.length; ++i) {
            IAeroGauge gauge = IAeroGauge(c.gauges[i]);
            require(IAerodromeSlipstreamPool(c.pools[i]).gauge() == c.gauges[i], "pool gauge mismatch");
            require(gauge.nft() == c.npm && gauge.pool() == c.pools[i], "gauge binding mismatch");
            address handler = AeroRewardDelivery.validate(c.gauges[i], c.receiptToken);
            if (handler != address(0)) {
                require(rootHandler == address(0) || rootHandler == handler, "root handler mismatch");
                rootHandler = handler;
            }
        }
        // Mirror setRewardBasePool, including its zero-pool route removal semantics.
        for (uint256 i; i < c.rewardBases.length; ++i) {
            address base = c.rewardBases[i];
            require(base != address(0) && base != c.receiptToken, "invalid reward base");
            address pool = c.rewardPools[i];
            if (pool == address(0)) continue;
            IAerodromeSlipstreamPool rewardPool = IAerodromeSlipstreamPool(pool);
            address token0 = rewardPool.token0();
            address token1 = rewardPool.token1();
            require(
                (token0 == c.receiptToken && token1 == base) || (token0 == base && token1 == c.receiptToken),
                "reward pool token mismatch"
            );
            require(
                IAerodromeSlipstreamFactory(c.factory).getPool(token0, token1, rewardPool.tickSpacing()) == pool,
                "reward pool factory mismatch"
            );
        }
    }
}
