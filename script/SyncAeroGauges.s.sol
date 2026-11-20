// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "./utils/AeroGaugeDiscovery.sol";
import "./utils/AeroGaugeRoles.sol";

interface IAeroRolesEnvironment {
    function envOr(string calldata name, bool defaultValue) external returns (bool);
}

// File cheatcodes used by the installed Foundry version; this repo pins an older forge-std interface.
interface IAeroSyncFiles {
    function unixTime() external view returns (uint256);
    function createDir(string calldata path, bool recursive) external;
    function serializeAddress(string calldata objectKey, string calldata key, address value)
        external
        returns (string memory);
    function serializeUint(string calldata objectKey, string calldata key, uint256 value)
        external
        returns (string memory);
    function writeJson(string calldata json, string calldata path) external;
}

/// @notice Default Safe batches, owner signing, or explicitly configured restricted Roles execution.
contract SyncAeroGauges is Script {
    function run() external {
        address target = vm.envAddress("AERO_GAUGE_MANAGER");
        require(target != address(0), "manager required");
        AeroGaugeDiscovery discovery = new AeroGaugeDiscovery();
        AeroGaugeDiscovery.Plan memory plan = discovery.scan(target);
        GaugeManager manager = GaugeManager(payable(target));
        address owner = manager.owner();
        console2.log("MANAGER", target);
        console2.log("CURRENT_OWNER", owner);
        for (uint256 i; i < plan.updates.length; ++i) {
            console2.log("POOL", plan.updates[i].pool);
            console2.log("PREVIOUS_GAUGE", plan.updates[i].previousGauge);
            console2.log("NEW_GAUGE", plan.updates[i].gauge);
        }
        if (IAeroRolesEnvironment(address(vm)).envOr("AERO_GAUGE_SYNC_ROLES", false)) {
            _syncWithRoles(target, plan);
            return;
        }
        if (vm.envBool("AERO_GAUGE_SYNC_SAFE")) {
            IAeroSyncFiles files = IAeroSyncFiles(address(vm));
            // Separate directories prevent a zero-update rerun from leaving apparently current old batches.
            string memory dir = string.concat(
                "gauge-sync/", vm.toString(target), "-", vm.toString(block.number), "-", vm.toString(files.unixTime())
            );
            files.createDir(dir, true);
            string memory summary = "summary";
            files.serializeAddress(summary, "manager", target);
            files.serializeAddress(summary, "owner", owner);
            files.serializeUint(summary, "block", block.number);
            files.serializeUint(summary, "scanned", plan.scanned);
            files.serializeUint(summary, "updates", plan.updates.length);
            files.serializeUint(summary, "unchanged", plan.unchanged);
            files.serializeUint(summary, "noGauge", plan.noGauge);
            files.serializeUint(summary, "inactive", plan.inactive);
            string memory json = files.serializeUint(summary, "incompatible", plan.incompatible);
            files.writeJson(json, string.concat(dir, "/summary.json"));
            // 25 calls per Safe transaction keeps batches comfortably bounded; zero updates writes no batch.
            for (uint256 start; start < plan.updates.length; start += 25) {
                uint256 end = start + 25 < plan.updates.length ? start + 25 : plan.updates.length;
                files.writeJson(
                    safeBatch(target, owner, plan.updates, start, end),
                    string.concat(dir, "/batch-", vm.toString(start / 25 + 1), ".json")
                );
            }
            console2.log("SAFE_OUTPUT", dir);
            return;
        }
        address sender = vm.envAddress("AERO_GAUGE_SENDER");
        require(sender == owner, "sender must be current owner (pending owner cannot configure)");
        require(owner.code.length == 0, "contract owner: generate Safe batches instead");
        vm.startBroadcast(sender);
        for (uint256 i; i < plan.updates.length; ++i) {
            manager.setGauge(plan.updates[i].pool, plan.updates[i].gauge);
        }
        vm.stopBroadcast();
    }

    /// @dev Only first registrations are automated. Replacements remain in the ordinary --safe report.
    function _syncWithRoles(address target, AeroGaugeDiscovery.Plan memory plan) internal {
        require(target == AeroGaugeRoles.MANAGER, "wrong manager for role");
        address roles = vm.envAddress("AERO_GAUGE_ROLES");
        address operator = vm.envAddress("AERO_GAUGE_OPERATOR");
        AeroGaugeRegistrationCondition condition = AeroGaugeRegistrationCondition(vm.envAddress("AERO_GAUGE_CONDITION"));
        AeroGaugeRoles.verifyInstance(roles);
        require(condition.roles() == roles, "condition/roles mismatch");
        require(
            operator != address(0) && operator != AeroGaugeRoles.SAFE && operator.code.length == 0,
            "dedicated EOA required"
        );
        require(IGaugeRolesSafe(AeroGaugeRoles.SAFE).isModuleEnabled(roles), "Safe module disabled");
        for (uint256 i; i < plan.updates.length; ++i) {
            AeroGaugeDiscovery.Entry memory entry = plan.updates[i];
            if (entry.previousGauge != address(0)) {
                console2.log("MANUAL_REPLACEMENT_POOL", entry.pool);
                continue;
            }
            condition.validate(entry.pool, entry.gauge);
        }
        vm.startBroadcast(operator);
        for (uint256 i; i < plan.updates.length; ++i) {
            AeroGaugeDiscovery.Entry memory entry = plan.updates[i];
            if (entry.previousGauge != address(0)) continue;
            require(
                IZodiacRoles(roles)
                    .execTransactionWithRole(
                        target,
                        0,
                        abi.encodeCall(GaugeManager.setGauge, (entry.pool, entry.gauge)),
                        0,
                        AeroGaugeRoles.ROLE,
                        true
                    ),
                "registration failed"
            );
            require(GaugeManager(payable(target)).poolToGauge(entry.pool) == entry.gauge, "registration mismatch");
        }
        vm.stopBroadcast();
    }

    function safeBatch(
        address manager,
        address owner,
        AeroGaugeDiscovery.Entry[] memory entries,
        uint256 start,
        uint256 end
    ) public returns (string memory) {
        string memory txs;
        for (uint256 i = start; i < end; ++i) {
            txs = string.concat(
                txs,
                i == start ? "" : ",",
                '{"to":"',
                vm.toString(manager),
                '","value":"0","data":"',
                vm.toString(abi.encodeCall(GaugeManager.setGauge, (entries[i].pool, entries[i].gauge))),
                '"}'
            );
        }
        return string.concat(
            '{"version":"1.0","chainId":"8453","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Aero gauge sync","description":"Review against a fresh scan before signing; gauge registration does not enable collateral.","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
            vm.toString(owner),
            '"},"transactions":[',
            txs,
            "]}"
        );
    }
}
