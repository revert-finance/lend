// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/console2.sol";
import "../../src/GaugeManager.sol";

interface IAeroPoolRegistry {
    function allPoolsLength() external view returns (uint256);
    function allPools(uint256 index) external view returns (address);
    function getPool(address token0, address token1, int24 spacing) external view returns (address);
}

interface IAeroGaugeActivation {
    function isActivated(address gauge) external view returns (bool);
}

/// @dev Off-chain script helper. Created before broadcast, never part of the deployed stack.
/// Scans the whole factory each time so replacements on old pools are found as well as new pools.
contract AeroGaugeDiscovery {
    address public constant FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address public constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address public constant GAUGE_FACTORY = 0xf437f62053ACB121665b8fDBfeA8F214FB8E589d;
    address public constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address public constant ROOT_HANDLER = 0x8C37F30F3c8fd48bEddb14086fa5148291D422C3;

    struct Entry {
        address pool;
        address gauge;
        address previousGauge;
    }

    struct Plan {
        Entry[] updates;
        uint256 scanned;
        uint256 unchanged;
        uint256 noGauge;
        uint256 inactive;
        uint256 incompatible;
    }

    function validate(address pool, address gauge) external view returns (bool activated) {
        require(pool.code.length != 0 && gauge.code.length != 0, "missing pool/gauge code");
        IAerodromeSlipstreamPool p = IAerodromeSlipstreamPool(pool);
        require(p.gauge() == gauge, "pool gauge changed");
        require(
            IAeroPoolRegistry(FACTORY).getPool(p.token0(), p.token1(), p.tickSpacing()) == pool, "pool factory mismatch"
        );
        IAeroGauge g = IAeroGauge(gauge);
        require(g.nft() == NPM && g.pool() == pool && g.gaugeFactory() == GAUGE_FACTORY, "gauge bindings");
        require(AeroRewardDelivery.validate(gauge, AERO) == ROOT_HANDLER, "unsupported root handler");
        return IAeroGaugeActivation(g.voter()).isActivated(gauge);
    }

    /// @param manager Zero for a fresh deployment; otherwise only missing/changed mappings are returned.
    function scan(address manager) external view returns (Plan memory plan) {
        require(block.chainid == 8453, "wrong chain");
        if (manager != address(0)) {
            GaugeManager m = GaugeManager(payable(manager));
            require(
                m.factory() == FACTORY && address(m.nonfungiblePositionManager()) == NPM, "wrong manager NPM/factory"
            );
            require(address(m.aeroToken()) == AERO, "wrong reward token");
            require(
                m.rootEmissionsHandler() == address(0) || m.rootEmissionsHandler() == ROOT_HANDLER,
                "wrong manager handler"
            );
        }
        plan.scanned = IAeroPoolRegistry(FACTORY).allPoolsLength();
        Entry[] memory found = new Entry[](plan.scanned);
        uint256 count;
        for (uint256 i; i < plan.scanned; ++i) {
            address pool = IAeroPoolRegistry(FACTORY).allPools(i);
            // A factory/read failure aborts the scan; it must not look like an empty successful inventory.
            address gauge = IAerodromeSlipstreamPool(pool).gauge();
            if (gauge == address(0)) {
                ++plan.noGauge;
                continue;
            }
            try this.validate(pool, gauge) returns (bool activated) {
                if (!activated) {
                    ++plan.inactive;
                    console2.log("SKIP inactive pool", pool);
                    continue;
                }
            } catch (bytes memory reason) {
                ++plan.incompatible;
                console2.log("SKIP incompatible pool", pool);
                console2.logBytes(reason);
                continue;
            }
            address previous = manager == address(0) ? address(0) : GaugeManager(payable(manager)).poolToGauge(pool);
            if (previous == gauge) {
                ++plan.unchanged;
            } else {
                found[count++] = Entry(pool, gauge, previous);
            }
        }
        plan.updates = new Entry[](count);
        for (uint256 i; i < count; ++i) {
            plan.updates[i] = found[i];
        }
        console2.log("FACTORY_POOLS", plan.scanned);
        console2.log("GAUGE_UPDATES", count);
        console2.log("UNCHANGED", plan.unchanged);
        console2.log("NO_GAUGE", plan.noGauge);
        console2.log("INACTIVE", plan.inactive);
        console2.log("INCOMPATIBLE", plan.incompatible);
    }
}
