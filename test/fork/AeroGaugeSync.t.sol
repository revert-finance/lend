// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../script/SyncAeroGauges.s.sol";

interface IAeroSyncJson {
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonBytes(string calldata json, string calldata key) external pure returns (bytes memory);
}

contract AeroGaugeSyncTest is Test {
    address constant FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant POOL = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    address constant SECOND = 0x16c70F04C3080a127486Cdf5a4C33c066bBF47C3;
    AeroGaugeDiscovery discovery;
    GaugeManager manager;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53296669);
        discovery = new AeroGaugeDiscovery();
        manager = new GaugeManager(
            INonfungiblePositionManager(NPM), IERC20(AERO), IVault(address(1)), address(2), address(3)
        );
    }

    function _onePool() internal {
        vm.mockCall(FACTORY, abi.encodeWithSignature("allPoolsLength()"), abi.encode(1));
        vm.mockCall(FACTORY, abi.encodeWithSignature("allPools(uint256)", 0), abi.encode(POOL));
    }

    function testAllLiveCompatibleGaugesRegisterAndSecondScanIsEmpty() public {
        AeroGaugeDiscovery.Plan memory plan = discovery.scan(address(manager));
        assertEq(plan.scanned, 525);
        assertGt(plan.updates.length, 100);
        assertEq(plan.incompatible, 0);
        for (uint256 i; i < plan.updates.length; ++i) {
            manager.setGauge(plan.updates[i].pool, plan.updates[i].gauge);
        }
        AeroGaugeDiscovery.Plan memory again = discovery.scan(address(manager));
        assertEq(again.updates.length, 0);
        assertEq(again.unchanged, plan.updates.length);
        assertEq(again.scanned, again.unchanged + again.noGauge + again.inactive + again.incompatible);
        assertEq(manager.poolToGauge(POOL), IAerodromeSlipstreamPool(POOL).gauge());
    }

    function testDetectsNewPoolOnLaterRun() public {
        _onePool();
        manager.setGauge(POOL, IAerodromeSlipstreamPool(POOL).gauge());
        assertEq(discovery.scan(address(manager)).updates.length, 0);
        vm.mockCall(FACTORY, abi.encodeWithSignature("allPoolsLength()"), abi.encode(2));
        vm.mockCall(FACTORY, abi.encodeWithSignature("allPools(uint256)", 1), abi.encode(SECOND));
        AeroGaugeDiscovery.Plan memory plan = discovery.scan(address(manager));
        assertEq(plan.updates.length, 1);
        assertEq(plan.updates[0].pool, SECOND);
    }

    function testDetectsReplacementAndPreservesOldGaugeRegistration() public {
        _onePool();
        address oldGauge = IAerodromeSlipstreamPool(POOL).gauge();
        manager.setGauge(POOL, oldGauge);
        address replacement = address(0x12345);
        vm.etch(replacement, oldGauge.code);
        // Gauge bindings include initialized storage, which etching runtime code alone does not copy.
        vm.mockCall(replacement, abi.encodeWithSignature("pool()"), abi.encode(POOL));
        vm.mockCall(replacement, abi.encodeWithSignature("nft()"), abi.encode(NPM));
        vm.mockCall(
            replacement, abi.encodeWithSignature("gaugeFactory()"), abi.encode(IAeroGauge(oldGauge).gaugeFactory())
        );
        vm.mockCall(replacement, abi.encodeWithSignature("voter()"), abi.encode(IAeroGauge(oldGauge).voter()));
        vm.mockCall(POOL, abi.encodeWithSignature("gauge()"), abi.encode(replacement));
        vm.mockCall(
            IAeroGauge(oldGauge).voter(), abi.encodeWithSignature("isActivated(address)", replacement), abi.encode(true)
        );
        AeroGaugeDiscovery.Plan memory plan = discovery.scan(address(manager));
        assertEq(plan.updates.length, 1);
        assertEq(plan.updates[0].previousGauge, oldGauge);
        assertEq(plan.updates[0].gauge, replacement);
        manager.setGauge(POOL, replacement);
        assertTrue(manager.knownGauges(oldGauge));
        assertTrue(manager.knownGauges(replacement));
        assertEq(discovery.scan(address(manager)).updates.length, 0);
    }

    function testInactiveGaugeIsSkippedWithoutClearingExistingMapping() public {
        _onePool();
        address gauge = IAerodromeSlipstreamPool(POOL).gauge();
        manager.setGauge(POOL, gauge);
        vm.mockCall(
            IAeroGauge(gauge).voter(), abi.encodeWithSignature("isActivated(address)", gauge), abi.encode(false)
        );
        AeroGaugeDiscovery.Plan memory plan = discovery.scan(address(manager));
        assertEq(plan.inactive, 1);
        assertEq(plan.updates.length, 0);
        assertEq(manager.poolToGauge(POOL), gauge);
    }

    function testNoGaugeIsSkipped() public {
        _onePool();
        vm.mockCall(POOL, abi.encodeWithSignature("gauge()"), abi.encode(address(0)));
        AeroGaugeDiscovery.Plan memory plan = discovery.scan(address(manager));
        assertEq(plan.noGauge, 1);
        assertEq(plan.updates.length, 0);
    }

    function testWrongNpmIsReportedAndExcluded() public {
        _onePool();
        address gauge = IAerodromeSlipstreamPool(POOL).gauge();
        vm.mockCall(gauge, abi.encodeWithSignature("nft()"), abi.encode(address(0xBAD)));
        AeroGaugeDiscovery.Plan memory plan = discovery.scan(address(manager));
        assertEq(plan.incompatible, 1);
        assertEq(plan.updates.length, 0);
    }

    function testZeroLiquidityDoesNotExcludeCompatibleGauge() public {
        _onePool();
        vm.mockCall(POOL, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(0)));
        assertEq(discovery.scan(address(manager)).updates.length, 1);
    }

    function testWrongChainFailsClosed() public {
        vm.chainId(1);
        vm.expectRevert(bytes("wrong chain"));
        discovery.scan(address(manager));
    }

    function testWrongManagerFailsClosed() public {
        vm.mockCall(address(manager), abi.encodeWithSignature("aeroToken()"), abi.encode(address(0xBAD)));
        vm.expectRevert(bytes("wrong reward token"));
        discovery.scan(address(manager));
    }

    function testSafePayloadTargetsManagerAndEncodesExactCall() public {
        _onePool();
        AeroGaugeDiscovery.Plan memory plan = discovery.scan(address(manager));
        SyncAeroGauges sync = new SyncAeroGauges();
        string memory json = sync.safeBatch(address(manager), address(this), plan.updates, 0, 1);
        IAeroSyncJson parser = IAeroSyncJson(address(vm));
        assertEq(parser.parseJsonAddress(json, ".transactions[0].to"), address(manager));
        assertEq(parser.parseJsonAddress(json, ".meta.createdFromSafeAddress"), address(this));
        bytes memory data = parser.parseJsonBytes(json, ".transactions[0].data");
        assertEq(data, abi.encodeCall(GaugeManager.setGauge, (POOL, IAerodromeSlipstreamPool(POOL).gauge())));
        (bool ok,) = address(manager).call(data);
        assertTrue(ok);
        assertEq(manager.poolToGauge(POOL), IAerodromeSlipstreamPool(POOL).gauge());
    }
}
