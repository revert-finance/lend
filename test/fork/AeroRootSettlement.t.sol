// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/GaugeManager.sol";
import "../../src/V3Vault.sol";
import "../../script/DeployAeroGaugeManager.s.sol";
import {MockVault} from "../unit/GaugeManager.t.sol";

interface IAeroMintNPM {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }
    function mint(MintParams calldata params) external payable returns (uint256, uint128, uint256, uint256);
}

interface IRootHandlerCall {
    function handleEmissions(address[] calldata recipients, uint128[] calldata amounts) external;
}

contract RootForkDeploymentScript is DeployAeroGaugeManager {
    Config private config;

    constructor(Config memory c) {
        config = c;
    }

    function _loadConfig() internal view override returns (Config memory) {
        return config;
    }
}

/// @dev Live Base fork: requires BASE_RPC_URL. No production transactions or mocked reward contracts.
contract AeroRootSettlementForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant RECEIPT = 0x6CdDa0E730744DC6fF67654B35350Adad05EceE7;
    address constant HANDLER = 0x8C37F30F3c8fd48bEddb14086fa5148291D422C3;
    address constant VOTER = 0x382409fad8503FbCdbB27A4211551fa03e884078;
    address constant POOL = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24;
    address constant ALICE = address(0xA11CE);
    GaugeManager manager;
    MockVault vault;
    IAerodromeSlipstreamPool pool;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53124108);
        vault = new MockVault();
        manager = new GaugeManager(
            INonfungiblePositionManager(NPM), IERC20(AERO), IVault(address(vault)), address(0), address(0)
        );
        pool = IAerodromeSlipstreamPool(POOL);
        manager.setGauge(POOL, pool.gauge());
        assertEq(manager.rootEmissionsHandler(), HANDLER);
    }

    function testLiveMintStakeClaimAeroAndWithdraw() public {
        address t0 = pool.token0();
        address t1 = pool.token1();
        deal(t0, address(this), 1 ether);
        deal(t1, address(this), 10_000e6);
        IERC20(t0).approve(NPM, type(uint256).max);
        IERC20(t1).approve(NPM, type(uint256).max);
        (, int24 tick,,,,) = pool.slot0();
        int24 center = tick / 100 * 100;
        (uint256 id,,,) = IAeroMintNPM(NPM)
            .mint(
                IAeroMintNPM.MintParams(
                    t0,
                    t1,
                    100,
                    center - 1000,
                    center + 1000,
                    1 ether,
                    10_000e6,
                    0,
                    0,
                    address(vault),
                    block.timestamp,
                    0
                )
            );
        vault.setOwner(id, ALICE);
        vm.startPrank(address(vault));
        INonfungiblePositionManager(NPM).approve(address(manager), id);
        manager.stakePosition(id);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 43_200);
        uint256 earnings = manager.positionRewards(id);
        assertGt(earnings, 1_000_000);
        vm.prank(ALICE);
        uint256 paid = manager.claimRewards(id, ALICE);
        assertGt(paid, 0);
        assertEq(IERC20(AERO).balanceOf(ALICE), paid);
        assertEq(IERC20(RECEIPT).balanceOf(address(manager)), 0);
        vm.prank(address(vault));
        manager.unstakePosition(id);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), address(vault));
        assertEq(manager.reservedRewards(), 0);
    }

    function testProductionManagerScriptOnBaseFork() public {
        address deployer = address(0xD3E10);
        address asset = pool.token1();
        vm.prank(deployer);
        V3Vault fresh = new V3Vault(
            "Root fork",
            "rootFork",
            asset,
            INonfungiblePositionManager(NPM),
            IInterestRateModel(address(0)),
            IV3Oracle(address(0))
        );
        DeployAeroGaugeManager.Config memory c;
        c.chainId = 8453;
        c.deployer = deployer;
        c.npm = NPM;
        c.factory = INonfungiblePositionManager(NPM).factory();
        c.receiptToken = AERO;
        c.vault = address(fresh);
        c.owner = ALICE;
        c.withdrawer = ALICE;
        c.pools = new address[](1);
        c.pools[0] = POOL;
        c.gauges = new address[](1);
        c.gauges[0] = pool.gauge();
        c.rewardBases = new address[](0);
        c.rewardPools = new address[](0);
        GaugeManager deployed = new RootForkDeploymentScript(c).run();
        assertEq(fresh.gaugeManager(), address(deployed));
        assertEq(deployed.rootEmissionsHandler(), HANDLER);
        assertEq(deployed.pendingOwner(), ALICE);
        assertLt(address(deployed).code.length, 24_576);
    }

    function testVerifiedRootHandlerThresholdAndOneForOnePayout() public {
        (bool ok, bytes memory data) = VOTER.staticcall(abi.encodeWithSignature("MIN_REDEEM_AMOUNT()"));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), 1_000_000);
        assertEq(IERC20Metadata(AERO).decimals(), 18);
        address recipient = address(0xB0B);
        uint128 dust = 400_000;
        uint128 nextReward = 1_000_000;
        // Fund only the handler's receipts; the actual handler, burn, local dispatch, voter and minter execute.
        deal(RECEIPT, HANDLER, IERC20(RECEIPT).balanceOf(HANDLER) + dust + nextReward);
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = dust;
        vm.prank(VOTER);
        IRootHandlerCall(HANDLER).handleEmissions(recipients, amounts);
        assertEq(IAeroRootEmissionsHandler(HANDLER).pendingRedeems(recipient), dust);
        assertEq(IERC20(AERO).balanceOf(recipient), 0);
        amounts[0] = nextReward;
        vm.prank(VOTER);
        IRootHandlerCall(HANDLER).handleEmissions(recipients, amounts);
        assertEq(IAeroRootEmissionsHandler(HANDLER).pendingRedeems(recipient), 0);
        assertEq(IERC20(AERO).balanceOf(recipient), uint256(dust) + nextReward);
    }
}
