// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../lib/AggregatorV3Interface.sol";
import "../../../src/InterestRateModel.sol";
import "../../../src/V3Oracle.sol";
import "../../../src/V3Vault.sol";
import "../../../src/GaugeManager.sol";
import "../../../src/interfaces/IVault.sol";
import "../../../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "../../../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";
import "../../../src/utils/FlashloanLiquidator.sol";
import "../../../src/utils/Constants.sol";

contract MockChainlinkFeed is AggregatorV3Interface {
    int256 private _answer;
    uint8 private immutable _decimals;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }
}

contract BaseAerodromeIntegrationTest is Test, Constants {
    uint256 constant BASE_FORK_BLOCK = 42_113_455;

    address constant BASE_WHALE = 0xa80f10c8e4126233B103C12917c94Db38f491c30;
    address constant ALICE = 0x3Ff13598141846B709Fe98788c98A2AE65C06769;
    address constant BOB = address(0xB0B);
    address constant OPERATOR = address(0x0A11003);
    uint256 constant TEST_NFT = 50994801;

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);

    V3Vault internal vault;
    V3Oracle internal oracle;
    InterestRateModel internal interestRateModel;
    GaugeManager internal gaugeManager;
    AutoRangeAndCompound internal autoRange;

    MockChainlinkFeed internal usdcUsdFeed;
    MockChainlinkFeed internal wethUsdFeed;

    IUniswapV3Pool internal wethUsdcPool;
    IUniswapV3Pool internal wethUsdcFlashPool;
    address internal wethUsdcGauge;
    address internal aeroUsdcPool;
    address internal aeroWethPool;
    address internal aeroCbbtcPool;

    function setUp() external {
        uint256 forkId = vm.createFork(_baseRpc(), BASE_FORK_BLOCK);
        vm.selectFork(forkId);

        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);
        usdcUsdFeed = new MockChainlinkFeed(1e8, 8);
        wethUsdFeed = new MockChainlinkFeed(3000e8, 8);

        address factory = NPM.factory();
        address poolAddress = IAerodromeSlipstreamFactory(factory).getPool(WETH, USDC, 100);
        if (poolAddress == address(0)) {
            revert InvalidPool();
        }
        wethUsdcPool = IUniswapV3Pool(poolAddress);
        wethUsdcGauge = IAerodromeSlipstreamPool(poolAddress).gauge();
        if (wethUsdcGauge == address(0)) {
            revert InvalidPool();
        }

        address flashPoolAddress = IAerodromeSlipstreamFactory(factory).getPool(WETH, USDC, 1);
        if (flashPoolAddress == address(0) || flashPoolAddress == poolAddress) {
            flashPoolAddress = IAerodromeSlipstreamFactory(factory).getPool(WETH, USDC, 10);
        }
        if (flashPoolAddress == address(0) || flashPoolAddress == poolAddress) {
            revert InvalidPool();
        }
        wethUsdcFlashPool = IUniswapV3Pool(flashPoolAddress);

        aeroUsdcPool = IAerodromeSlipstreamFactory(factory).getPool(AERO, USDC, 2000);
        if (aeroUsdcPool == address(0)) {
            revert InvalidPool();
        }

        aeroWethPool = IAerodromeSlipstreamFactory(factory).getPool(AERO, WETH, 200);
        if (aeroWethPool == address(0)) {
            revert InvalidPool();
        }

        aeroCbbtcPool = IAerodromeSlipstreamFactory(factory).getPool(AERO, CBBTC, 200);
        if (aeroCbbtcPool == address(0)) {
            revert InvalidPool();
        }

        oracle = new V3Oracle(NPM, USDC, address(0));
        oracle.setMaxPoolPriceDifference(type(uint16).max);
        oracle.setTokenConfig(USDC, usdcUsdFeed, 30 days, IUniswapV3Pool(address(0)), 0, V3Oracle.Mode.TWAP, 0);
        oracle.setTokenConfig(WETH, wethUsdFeed, 30 days, wethUsdcPool, 60, V3Oracle.Mode.TWAP, 0);

        vault = new V3Vault("Revert Lend Base USDC", "rlBaseUSDC", USDC, NPM, interestRateModel, oracle);
        vault.setTokenConfig(USDC, uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(WETH, uint32(Q32 * 8 / 10), type(uint32).max);
        vault.setLimits(0, 20_000_000e6, 20_000_000e6, 20_000_000e6, 20_000_000e6);
        vault.setReserveFactor(0);

        gaugeManager = new GaugeManager(NPM, IERC20(AERO), IVault(address(vault)), address(0), address(0));
        gaugeManager.setGauge(poolAddress, wethUsdcGauge);
        gaugeManager.setRewardBasePool(USDC, aeroUsdcPool);
        gaugeManager.setRewardBasePool(WETH, aeroWethPool);
        gaugeManager.setRewardBasePool(CBBTC, aeroCbbtcPool);
        vault.setGaugeManager(address(gaugeManager));

        autoRange = new AutoRangeAndCompound(NPM, OPERATOR, OPERATOR, 60, 200, address(0), address(0));
        autoRange.setVault(address(vault));
        vault.setTransformer(address(autoRange), true);

        address owner = NPM.ownerOf(TEST_NFT);
        if (owner != ALICE) {
            vm.prank(owner);
            NPM.safeTransferFrom(owner, ALICE, TEST_NFT);
        }

        _seedVaultLiquidity(150_000e6);
    }

    function testBaseSetupSanity() external {
        assertEq(vault.gaugeManager(), address(gaugeManager));
        assertEq(gaugeManager.poolToGauge(address(wethUsdcPool)), wethUsdcGauge);
    }

    function testOracleGetValueForBasePosition() external {
        uint256 tokenId = TEST_NFT;

        (uint256 value, uint256 feeValue, uint256 price0X96, uint256 price1X96) = oracle.getValue(tokenId, USDC, false);
        assertGt(value, 0);
        assertGe(value, feeValue);
        assertGt(price0X96, 0);
        assertGt(price1X96, 0);
    }

    function testVaultCreateBorrowRepayRemove() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        assertGt(collateralValue, 0);

        uint256 borrowAmount = collateralValue * vault.BORROW_SAFETY_BUFFER_X32() / Q32 / 2;
        if (borrowAmount > 50_000e6) {
            borrowAmount = 50_000e6;
        }
        assertGt(borrowAmount, 0);

        vm.prank(ALICE);
        vault.borrow(tokenId, borrowAmount);
        assertGe(IERC20(USDC).balanceOf(ALICE), borrowAmount);

        vm.prank(BASE_WHALE);
        IERC20(USDC).transfer(ALICE, 10e6);

        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        (uint256 debtShares) = vault.loans(tokenId);
        vault.repay(tokenId, debtShares, true);
        vault.remove(tokenId, ALICE, "");
        vm.stopPrank();

        assertEq(NPM.ownerOf(tokenId), ALICE);
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertEq(debtAfter, 0);
    }

    function testStakeAndUnstakePosition() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);

        assertEq(gaugeManager.tokenIdToGauge(tokenId), wethUsdcGauge);
        assertEq(NPM.ownerOf(tokenId), wethUsdcGauge);

        vm.prank(ALICE);
        vault.unstakePosition(tokenId);

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(NPM.ownerOf(tokenId), address(vault));
    }

    function testRemoveAutoUnstakesPosition() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);

        vm.prank(ALICE);
        vault.remove(tokenId, ALICE, "");

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(NPM.ownerOf(tokenId), ALICE);
    }

    function testCompoundRewardsOptionalNoSwap() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);

        vm.prank(ALICE);
        gaugeManager.compoundRewards(tokenId, 0, 5_000, block.timestamp + 1 hours);

        assertEq(gaugeManager.tokenIdToGauge(tokenId), wethUsdcGauge);
        assertEq(NPM.ownerOf(tokenId), wethUsdcGauge);
    }

    function testDecreaseLiquidityAndCollectRestakesIfStaked() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);

        (,,,,,,, uint128 liquidity,,,,) = NPM.positions(tokenId);
        assertGt(liquidity, 0);

        vm.prank(ALICE);
        vault.decreaseLiquidityAndCollect(
            IVault.DecreaseLiquidityAndCollectParams({
                tokenId: tokenId,
                liquidity: liquidity / 5,
                amount0Min: 0,
                amount1Min: 0,
                feeAmount0: 0,
                feeAmount1: 0,
                deadline: block.timestamp + 1 hours,
                recipient: ALICE
            })
        );

        assertEq(gaugeManager.tokenIdToGauge(tokenId), wethUsdcGauge);
        assertEq(NPM.ownerOf(tokenId), wethUsdcGauge);
    }

    function testAutoRangeAutoCompoundWithVaultOnStakedPosition() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.startPrank(ALICE);
        vault.stakePosition(tokenId);
        vault.approveTransform(tokenId, address(autoRange), true);
        autoRange.configToken(
            tokenId,
            address(vault),
            AutoRangeAndCompound.PositionConfig({
                lowerTickLimit: 0,
                upperTickLimit: 0,
                lowerTickDelta: 0,
                upperTickDelta: 0,
                token0SlippageX64: 0,
                token1SlippageX64: 0,
                onlyFees: false,
                autoCompound: true,
                maxRewardX64: 0,
                autoCompoundMin0: 0,
                autoCompoundMin1: 0,
                autoCompoundRewardMin: 0
            })
        );
        vm.stopPrank();

        vm.prank(OPERATOR);
        autoRange.autoCompoundWithVault(
            AutoRangeAndCompound.AutoCompoundParams({
                tokenId: tokenId, swap0To1: false, amountIn: 0, deadline: block.timestamp + 1 hours
            }),
            address(vault)
        );

        assertEq(gaugeManager.tokenIdToGauge(tokenId), wethUsdcGauge);
        assertEq(vault.ownerOf(tokenId), ALICE);
    }

    function testAutoRangeAutoCompoundWithVaultAndRewardCompoundOnStakedPosition() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.startPrank(ALICE);
        vault.stakePosition(tokenId);
        vault.approveTransform(tokenId, address(autoRange), true);
        autoRange.configToken(
            tokenId,
            address(vault),
            AutoRangeAndCompound.PositionConfig({
                lowerTickLimit: 0,
                upperTickLimit: 0,
                lowerTickDelta: 0,
                upperTickDelta: 0,
                token0SlippageX64: 0,
                token1SlippageX64: 0,
                onlyFees: false,
                autoCompound: true,
                maxRewardX64: 0,
                autoCompoundMin0: 0,
                autoCompoundMin1: 0,
                autoCompoundRewardMin: 0
            })
        );
        vm.stopPrank();

        vm.prank(OPERATOR);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            AutoRangeAndCompound.AutoCompoundParams({
                tokenId: tokenId, swap0To1: false, amountIn: 0, deadline: block.timestamp + 1 hours
            }),
            address(vault),
            IVault.RewardCompoundParams({
                minAeroReward: 0,
                aeroSplitBps: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        assertEq(gaugeManager.tokenIdToGauge(tokenId), wethUsdcGauge);
        assertEq(vault.ownerOf(tokenId), ALICE);
    }

    function testAutoRangeRewardCompoundEnforcesConfigMinAeroReward() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.startPrank(ALICE);
        vault.stakePosition(tokenId);
        vault.approveTransform(tokenId, address(autoRange), true);
        autoRange.configToken(
            tokenId,
            address(vault),
            AutoRangeAndCompound.PositionConfig({
                lowerTickLimit: 0,
                upperTickLimit: 0,
                lowerTickDelta: 0,
                upperTickDelta: 0,
                token0SlippageX64: 0,
                token1SlippageX64: 0,
                onlyFees: false,
                autoCompound: true,
                maxRewardX64: 0,
                autoCompoundMin0: 0,
                autoCompoundMin1: 0,
                autoCompoundRewardMin: 1
            })
        );
        vm.stopPrank();

        vm.prank(OPERATOR);
        vm.expectRevert(Constants.NotEnoughReward.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            AutoRangeAndCompound.AutoCompoundParams({
                tokenId: tokenId, swap0To1: false, amountIn: 0, deadline: block.timestamp + 1 hours
            }),
            address(vault),
            IVault.RewardCompoundParams({
                minAeroReward: 0,
                aeroSplitBps: 0,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    function testFlashloanLiquidationHappyPath() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        assertGt(collateralValue, 0);

        // Borrow close to the allowed buffer to make interest-driven unhealthy state reachable.
        uint256 borrowAmount = collateralValue * vault.BORROW_SAFETY_BUFFER_X32() / Q32;
        if (borrowAmount > 140_000e6) {
            borrowAmount = 140_000e6;
        }
        if (borrowAmount > 1e6) {
            borrowAmount -= 1e6;
        }
        assertGt(borrowAmount, 0);

        vm.prank(ALICE);
        vault.borrow(tokenId, borrowAmount);

        // Deterministically force unhealthy state for liquidation path validation.
        vault.setTokenConfig(WETH, 0, type(uint32).max);

        (,,, uint256 liquidationCost, uint256 liquidationValue) = vault.loanInfo(tokenId);

        assertGt(liquidationValue, 0, "position not liquidatable");
        assertGt(liquidationCost, 0, "missing liquidation cost");

        FlashloanLiquidator liquidator = new FlashloanLiquidator(NPM, address(0), address(0));

        // No swaps in this happy path; pre-fund helper with USDC so callback always has repayment headroom.
        vm.prank(BASE_WHALE);
        IERC20(USDC).transfer(address(liquidator), liquidationCost + 10_000e6);

        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(BOB);

        vm.prank(BOB);
        liquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                tokenId: tokenId,
                vault: IVault(address(vault)),
                flashLoanPool: wethUsdcFlashPool,
                amount0In: 0,
                swapData0: "",
                amount1In: 0,
                swapData1: "",
                minReward: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        (uint256 debtAfter,,, uint256 liquidationCostAfter, uint256 liquidationValueAfter) = vault.loanInfo(tokenId);
        assertEq(debtAfter, 0);
        assertEq(liquidationCostAfter, 0);
        assertEq(liquidationValueAfter, 0);
        assertEq(vault.loans(tokenId), 0);

        assertEq(vault.ownerOf(tokenId), ALICE);
        assertEq(NPM.ownerOf(tokenId), address(vault));
        assertGt(IERC20(USDC).balanceOf(BOB), bobUsdcBefore);
    }

    function testSetGaugeManagerOnlyOnce() external {
        vm.expectRevert(Constants.GaugeManagerAlreadySet.selector);
        vault.setGaugeManager(address(0x1234));
    }

    function testStakeRevertsForNonDepositor() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.expectRevert(Constants.NotDepositor.selector);
        vm.prank(BOB);
        vault.stakePosition(tokenId);
    }

    function testUnstakeRevertsForUnauthorizedCaller() external {
        uint256 tokenId = TEST_NFT;
        _depositCollateral(tokenId, ALICE);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(BOB);
        vault.unstakePosition(tokenId);
    }

    function _seedVaultLiquidity(uint256 amount) internal {
        vm.startPrank(BASE_WHALE);
        IERC20(USDC).approve(address(vault), amount);
        vault.deposit(amount, BASE_WHALE);
        vm.stopPrank();
    }

    function _depositCollateral(uint256 tokenId, address owner) internal {
        vm.startPrank(owner);
        NPM.approve(address(vault), tokenId);
        vault.create(tokenId, owner);
        vm.stopPrank();
    }

    function _baseRpc() internal returns (string memory rpcUrl) {
        try vm.envString("BASE_RPC_URL") returns (string memory url) {
            return url;
        } catch {
            return string.concat("https://rpc.ankr.com/base/", vm.envString("ANKR_API_KEY"));
        }
    }
}
