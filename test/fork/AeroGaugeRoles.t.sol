// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../script/SyncAeroGauges.s.sol";

contract AeroRolesSyncHarness is SyncAeroGauges {
    function sync(AeroGaugeDiscovery.Plan memory plan) external {
        _syncWithRoles(AeroGaugeRoles.MANAGER, plan);
    }
}

interface IAeroRolesOwned {
    function owner() external view returns (address);
}

/// @dev Uses actual Base Safe 1.3.0, Roles 2.1.1 and its libraries, factory/registry/gauge and GaugeManager.
/// Only governance setup/revocation calls impersonate the Safe. Registration uses the operator path.
contract AeroGaugeRolesForkTest is Test {
    address constant POOL = 0x599C4225FE90214795a0be228D20d7680f8CED15;
    address constant OPERATOR = address(0xA11CE);
    IZodiacRoles roles;
    AeroGaugeRegistrationCondition condition;
    GaugeManager manager;
    address gauge;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 59778757);
        AeroGaugeRoles.verifyDependencies();
        bytes memory init = abi.encodeCall(
            IZodiacRoles.setUp, (abi.encode(AeroGaugeRoles.SAFE, AeroGaugeRoles.SAFE, AeroGaugeRoles.SAFE))
        );
        roles = IZodiacRoles(
            IZodiacProxyFactory(AeroGaugeRoles.PROXY_FACTORY).deployModule(AeroGaugeRoles.IMPLEMENTATION, init, 991122)
        );
        condition = new AeroGaugeRegistrationCondition(address(roles));
        manager = GaugeManager(payable(AeroGaugeRoles.MANAGER));
        gauge = IAerodromeSlipstreamPool(POOL).gauge();
        assertEq(manager.poolToGauge(POOL), address(0));
    }

    function _enable() internal {
        AeroGaugeRoles.Call[] memory calls = AeroGaugeRoles.setupCalls(address(roles), address(condition), OPERATOR);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(AeroGaugeRoles.SAFE);
            (bool ok, bytes memory reason) = calls[i].to.call(calls[i].data);
            if (!ok) {
                assembly { revert(add(reason, 32), mload(reason)) }
            }
        }
    }

    function _register() internal returns (bool) {
        return roles.execTransactionWithRole(
            AeroGaugeRoles.MANAGER,
            0,
            abi.encodeCall(GaugeManager.setGauge, (POOL, gauge)),
            0,
            AeroGaugeRoles.ROLE,
            true
        );
    }

    function testActualSafeRegistersOfficialGaugeAndKeepsOwnership() public {
        assertFalse(IGaugeRolesSafe(AeroGaugeRoles.SAFE).isModuleEnabled(address(roles)));
        _enable();
        vm.prank(OPERATOR);
        assertTrue(_register());
        assertEq(manager.poolToGauge(POOL), gauge);
        assertEq(manager.owner(), AeroGaugeRoles.SAFE);
        assertEq(IAeroRolesOwned(address(manager.vault())).owner(), AeroGaugeRoles.SAFE);
    }

    function testSyncRegistersNewButLeavesReplacementsForSafe() public {
        _enable();
        vm.setEnv("AERO_GAUGE_ROLES", vm.toString(address(roles)));
        vm.setEnv("AERO_GAUGE_CONDITION", vm.toString(address(condition)));
        vm.setEnv("AERO_GAUGE_OPERATOR", vm.toString(OPERATOR));
        AeroGaugeDiscovery.Plan memory plan;
        plan.updates = new AeroGaugeDiscovery.Entry[](2);
        plan.updates[0] = AeroGaugeDiscovery.Entry(POOL, gauge, address(0));
        // A replacement entry must never reach either validation or execution.
        plan.updates[1] = AeroGaugeDiscovery.Entry(address(0xBAD), address(0xBAD), gauge);
        AeroRolesSyncHarness sync = new AeroRolesSyncHarness();
        sync.sync(plan);
        assertEq(manager.poolToGauge(POOL), gauge);
        assertEq(manager.poolToGauge(address(0xBAD)), address(0));
        plan.updates = new AeroGaugeDiscovery.Entry[](0);
        sync.sync(plan);
    }

    function testDisabledModuleCannotExecute() public {
        vm.prank(OPERATOR);
        vm.expectRevert();
        _register();
    }

    function testUnprivilegedCallerCannotExecute() public {
        _enable();
        vm.expectRevert();
        _register();
    }

    function testRepeatAndReplacementDenied() public {
        _enable();
        vm.prank(OPERATOR);
        _register();
        vm.prank(OPERATOR);
        vm.expectRevert();
        _register();
        vm.mockCall(POOL, abi.encodeWithSignature("gauge()"), abi.encode(address(0xBAD)));
        vm.prank(OPERATOR);
        vm.expectRevert();
        roles.execTransactionWithRole(
            AeroGaugeRoles.MANAGER,
            0,
            abi.encodeCall(GaugeManager.setGauge, (POOL, address(0xBAD))),
            0,
            AeroGaugeRoles.ROLE,
            true
        );
        assertEq(manager.poolToGauge(POOL), gauge);
    }

    function testInactiveGaugeDeniedAtExecution() public {
        _enable();
        vm.mockCall(condition.VOTER(), abi.encodeWithSignature("isActivated(address)", gauge), abi.encode(false));
        vm.prank(OPERATOR);
        vm.expectRevert();
        _register();
        assertEq(manager.poolToGauge(POOL), address(0));
    }

    function testOtherAdministrationAndTargetsDenied() public {
        _enable();
        address vault = address(manager.vault());
        vm.startPrank(OPERATOR);
        vm.expectRevert();
        roles.execTransactionWithRole(
            AeroGaugeRoles.MANAGER,
            0,
            abi.encodeWithSignature("transferOwnership(address)", OPERATOR),
            0,
            AeroGaugeRoles.ROLE,
            true
        );
        vm.expectRevert();
        roles.execTransactionWithRole(
            AeroGaugeRoles.SAFE,
            0,
            abi.encodeWithSignature("enableModule(address)", OPERATOR),
            0,
            AeroGaugeRoles.ROLE,
            true
        );
        vm.expectRevert();
        roles.scopeTarget(AeroGaugeRoles.ROLE, vault);
        vm.stopPrank();
        assertEq(manager.owner(), AeroGaugeRoles.SAFE);
    }

    function testValueAndDelegateCallDenied() public {
        _enable();
        bytes memory data = abi.encodeCall(GaugeManager.setGauge, (POOL, gauge));
        vm.startPrank(OPERATOR);
        vm.expectRevert();
        roles.execTransactionWithRole(AeroGaugeRoles.MANAGER, 1, data, 0, AeroGaugeRoles.ROLE, true);
        vm.expectRevert();
        roles.execTransactionWithRole(AeroGaugeRoles.MANAGER, 0, data, 1, AeroGaugeRoles.ROLE, true);
        vm.stopPrank();
    }

    function testForgedAndMalformedCallsDenied() public {
        _enable();
        vm.startPrank(OPERATOR);
        vm.expectRevert();
        roles.execTransactionWithRole(
            AeroGaugeRoles.MANAGER,
            0,
            abi.encodeCall(GaugeManager.setGauge, (POOL, address(0xBAD))),
            0,
            AeroGaugeRoles.ROLE,
            true
        );
        vm.expectRevert();
        roles.execTransactionWithRole(
            AeroGaugeRoles.MANAGER,
            0,
            abi.encodePacked(abi.encodeCall(GaugeManager.setGauge, (POOL, gauge)), bytes1(0)),
            0,
            AeroGaugeRoles.ROLE,
            true
        );
        vm.stopPrank();
    }

    function testRoleRevocationImmediatelyStopsOperator() public {
        _enable();
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = AeroGaugeRoles.ROLE;
        bool[] memory enabled = new bool[](1);
        vm.prank(AeroGaugeRoles.SAFE);
        roles.assignRoles(OPERATOR, keys, enabled);
        vm.prank(OPERATOR);
        vm.expectRevert();
        _register();
    }

    function testDisablingModuleImmediatelyStopsOperator() public {
        _enable(); // enableModule inserts this instance at the head of the Safe's linked list.
        vm.prank(AeroGaugeRoles.SAFE);
        IGaugeRolesSafe(AeroGaugeRoles.SAFE).disableModule(address(1), address(roles));
        vm.prank(OPERATOR);
        vm.expectRevert();
        _register();
    }
}
