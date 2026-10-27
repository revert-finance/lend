// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../script/DeployAeroGaugeManagerLocal.s.sol";
import "../mocks/AeroRootDeliveryFixture.sol";

contract AeroDeploymentHarness is DeployAeroGaugeManagerLocal {
    function config() external view returns (Config memory) {
        return _loadConfig();
    }

    function validateConfig(Config memory c) external view {
        _validate(c);
    }
}

contract DeployAeroGaugeManagerTest is Test {
    AeroDeploymentHarness script;

    function setUp() public {
        script = new AeroDeploymentHarness();
        script.setUp();
    }

    function testDeployBindsVaultConfiguresRoutesAndTransfersOwnershipInTwoSteps() public {
        DeployAeroGaugeManager.Config memory c = script.config();
        GaugeManager manager = script.run();
        assertEq(IAeroVaultSetup(c.vault).gaugeManager(), address(manager));
        assertEq(address(manager.vault()), c.vault);
        assertEq(address(manager.aeroToken()), c.receiptToken);
        assertEq(manager.poolToGauge(c.pools[0]), c.gauges[0]);
        assertTrue(manager.knownGauges(c.gauges[0]));
        assertEq(manager.rewardBasePools(c.rewardBases[0]), c.rewardPools[0]);
        assertEq(manager.withdrawer(), c.withdrawer);
        assertEq(manager.owner(), c.deployer);
        assertEq(manager.pendingOwner(), c.owner);
        vm.prank(c.owner);
        manager.acceptOwnership();
        assertEq(manager.owner(), c.owner);
        assertEq(manager.pendingOwner(), address(0));
    }

    function testDeployPreflightAndBindingSupportRootSettlement() public {
        DeployAeroGaugeManager.Config memory c = script.config();
        RootSettlementFixture handler = new RootSettlementFixture(MockERC20Token(c.receiptToken));
        RootTopologyFixture topology = new RootTopologyFixture(address(handler), c.receiptToken);
        handler.setVoter(address(topology));
        AeroGaugeFixture(c.gauges[0]).setVoter(address(topology));
        script.validateConfig(c);
        GaugeManager manager = script.run();
        assertEq(manager.rootEmissionsHandler(), address(handler));
        assertEq(manager.poolToGauge(c.pools[0]), c.gauges[0]);
        assertEq(IAeroVaultSetup(c.vault).gaugeManager(), address(manager));
    }

    function testRootPreflightRejectsWrongPayoutTokenBeforeBinding() public {
        DeployAeroGaugeManager.Config memory c = script.config();
        RootSettlementFixture handler = new RootSettlementFixture(MockERC20Token(c.receiptToken));
        RootTopologyFixture topology = new RootTopologyFixture(address(handler), address(0xBAD));
        handler.setVoter(address(topology));
        AeroGaugeFixture(c.gauges[0]).setVoter(address(topology));
        vm.expectRevert(GaugeManager.UnsupportedRewardDelivery.selector);
        script.run();
        assertEq(IAeroVaultSetup(c.vault).gaugeManager(), address(0));
    }

    function testRejectsAlreadyBoundVault() public {
        script.run();
        vm.expectRevert(bytes("vault already bound"));
        script.run();
    }

    function testRejectsWrongChainAndVaultOwnerBeforeDeployment() public {
        DeployAeroGaugeManager.Config memory c = script.config();
        c.chainId = 8453;
        vm.expectRevert(bytes("wrong chain"));
        script.validateConfig(c);
        c.chainId = block.chainid;
        c.deployer = address(0xBAD);
        vm.expectRevert(bytes("deployer must own fresh vault"));
        script.validateConfig(c);
    }

    function testRejectsPoolGaugeMismatchInPreflight() public {
        DeployAeroGaugeManager.Config memory c = script.config();
        MockPool(c.pools[0]).setGauge(address(0xBAD));
        vm.expectRevert(bytes("pool gauge mismatch"));
        script.run();
        assertEq(IAeroVaultSetup(c.vault).gaugeManager(), address(0));
    }

    function testRejectsRewardPoolTokenMismatchInPreflight() public {
        DeployAeroGaugeManager.Config memory c = script.config();
        c.rewardPools[0] = address(new MockPool(c.rewardBases[0], address(0xBAD), 100));
        vm.expectRevert(bytes("reward pool token mismatch"));
        script.validateConfig(c);
    }

    function testRejectsRewardPoolFactoryMismatchInPreflight() public {
        DeployAeroGaugeManager.Config memory c = script.config();
        MockPool rewardPool = MockPool(c.rewardPools[0]);
        MockSlipstreamFactory(c.factory)
            .setPool(rewardPool.token0(), rewardPool.token1(), rewardPool.tickSpacing(), address(0xBAD));
        vm.expectRevert(bytes("reward pool factory mismatch"));
        script.run();
        assertEq(IAeroVaultSetup(c.vault).gaugeManager(), address(0));
    }

    function testRejectsInvalidRewardBasesEvenForRouteRemoval() public {
        DeployAeroGaugeManager.Config memory c = script.config();
        c.rewardPools[0] = address(0);
        c.rewardBases[0] = address(0);
        vm.expectRevert(bytes("invalid reward base"));
        script.validateConfig(c);
        c.rewardBases[0] = c.receiptToken;
        vm.expectRevert(bytes("invalid reward base"));
        script.validateConfig(c);
    }

    function testPreflightAcceptsRouteRemovalAndEmptyRewardRoutes() public view {
        DeployAeroGaugeManager.Config memory c = script.config();
        c.rewardPools[0] = address(0);
        script.validateConfig(c);
        c.rewardBases = new address[](0);
        c.rewardPools = new address[](0);
        script.validateConfig(c);
    }
}
