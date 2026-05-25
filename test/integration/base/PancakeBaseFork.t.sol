// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../../lib/AggregatorV3Interface.sol";
import "../../../lib/IWETH9.sol";
import "../../../src/InterestRateModel.sol";
import "../../../src/PancakeStakingManager.sol";
import "../../../src/V3Oracle.sol";
import "../../../src/V3Vault.sol";
import "../../../src/interfaces/IVault.sol";
import "../../../src/interfaces/pancake/IPancakeMasterChefV3.sol";
import "../../../src/utils/Constants.sol";

interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IPancakeMasterChefV3View is IPancakeMasterChefV3 {
    function latestPeriodEndTime() external view returns (uint256);
    function poolLength() external view returns (uint256);
    function totalAllocPoint() external view returns (uint256);

    function userPositionInfos(uint256 tokenId)
        external
        view
        returns (
            uint128 liquidity,
            uint128 boostLiquidity,
            int24 tickLower,
            int24 tickUpper,
            uint256 rewardGrowthInside,
            uint256 reward,
            address user,
            uint256 pid
        );
}

contract MockBaseChainlinkFeed is AggregatorV3Interface {
    int256 private immutable _answer;
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

contract NoopPancakeTransformer {
    function execute() external {}
}

contract PancakeBaseForkTest is Test, Constants {
    uint256 internal constant BASE_FORK_BLOCK = 46_475_796;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant LENDER = address(0x1EAD);

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CAKE = 0x3055913c90Fcc1A6CE9a358911721eEb942013A1;

    INonfungiblePositionManager internal constant NPM =
        INonfungiblePositionManager(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364);
    IPancakeV3Factory internal constant FACTORY = IPancakeV3Factory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);
    IPancakeMasterChefV3View internal constant MASTER_CHEF =
        IPancakeMasterChefV3View(0xC6A2Db661D5a5690172d8eB0a7DEA2d3008665A3);

    IUniswapV3Pool internal constant WETH_USDC_POOL = IUniswapV3Pool(0xB775272E537cc670C65DC852908aD47015244EaF);
    IUniswapV3Pool internal constant CAKE_WETH_POOL = IUniswapV3Pool(0x03bf0449150ca9E84c6fae422cB741710246EA5f);
    IUniswapV3Pool internal constant CAKE_USDC_POOL = IUniswapV3Pool(0xBf1713B92F4212F0fAC0078e2cea7E182D40078B);

    V3Vault internal vault;
    V3Oracle internal oracle;
    InterestRateModel internal interestRateModel;
    PancakeStakingManager internal stakingManager;
    NoopPancakeTransformer internal noopTransformer;

    MockBaseChainlinkFeed internal usdcUsdFeed;
    MockBaseChainlinkFeed internal wethUsdFeed;

    function setUp() external {
        uint256 forkId = vm.createFork(_baseRpc(), BASE_FORK_BLOCK);
        vm.selectFork(forkId);

        _assertLivePancakeConfig();

        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);
        usdcUsdFeed = new MockBaseChainlinkFeed(1e8, 8);
        wethUsdFeed = new MockBaseChainlinkFeed(3_800e8, 8);

        oracle = new V3Oracle(NPM, USDC, address(0));
        oracle.setMaxPoolPriceDifference(type(uint16).max);
        oracle.setTokenConfig(USDC, usdcUsdFeed, 30 days, IUniswapV3Pool(address(0)), 0, V3Oracle.Mode.CHAINLINK, 0);
        oracle.setTokenConfig(WETH, wethUsdFeed, 30 days, WETH_USDC_POOL, 60, V3Oracle.Mode.TWAP, 0);

        vault = new V3Vault("Revert Lend Base Pancake USDC", "rlPancakeUSDC", USDC, NPM, interestRateModel, oracle);
        vault.setTokenConfig(USDC, uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(WETH, uint32(Q32 * 8 / 10), type(uint32).max);
        vault.setLimits(0, 50_000_000e6, 50_000_000e6, 50_000_000e6, 50_000_000e6);
        vault.setReserveFactor(0);

        stakingManager =
            new PancakeStakingManager(NPM, MASTER_CHEF, IERC20(CAKE), IVault(address(vault)), address(0), address(0));
        stakingManager.setGauge(address(WETH_USDC_POOL), address(MASTER_CHEF));
        stakingManager.setRewardBasePool(WETH, address(CAKE_WETH_POOL));
        stakingManager.setRewardBasePool(USDC, address(CAKE_USDC_POOL));
        vault.setGaugeManager(address(stakingManager));

        noopTransformer = new NoopPancakeTransformer();
        vault.setTransformer(address(noopTransformer), true);

        _seedVaultLiquidity(1_000_000e6);
    }

    function testBasePancakeConfigSanity() external {
        assertEq(address(NPM), MASTER_CHEF.nonfungiblePositionManager());
        assertEq(CAKE, MASTER_CHEF.CAKE());
        assertEq(NPM.factory(), address(FACTORY));
        assertGt(MASTER_CHEF.poolLength(), 0);
        assertGt(MASTER_CHEF.totalAllocPoint(), 0);
        assertGt(MASTER_CHEF.latestPeriodEndTime(), block.timestamp);
        assertEq(stakingManager.poolToGauge(address(WETH_USDC_POOL)), address(MASTER_CHEF));
        assertEq(stakingManager.rewardBasePools(WETH), address(CAKE_WETH_POOL));
        assertEq(stakingManager.rewardBasePools(USDC), address(CAKE_USDC_POOL));
        assertEq(vault.gaugeManager(), address(stakingManager));
    }

    function testVaultCreateBorrowRepayRemoveOnPancakePosition() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        assertGt(collateralValue, 0);

        uint256 borrowAmount = _min(collateralValue / 4, 5_000e6);
        assertGt(borrowAmount, 0);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(ALICE);

        vm.prank(ALICE);
        vault.borrow(tokenId, borrowAmount);
        assertEq(IERC20(USDC).balanceOf(ALICE) - aliceUsdcBefore, borrowAmount);

        deal(USDC, ALICE, borrowAmount + 100e6);
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

    function testStakeRegistersAdapterAsMasterChefUser() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);

        (,,,,,, address user, uint256 pid) = MASTER_CHEF.userPositionInfos(tokenId);
        assertEq(user, address(stakingManager));
        assertEq(pid, MASTER_CHEF.v3PoolAddressPid(address(WETH_USDC_POOL)));
        assertEq(stakingManager.tokenIdToGauge(tokenId), address(MASTER_CHEF));
        assertEq(NPM.ownerOf(tokenId), address(MASTER_CHEF));
    }

    function testClaimRewardsForwardsCakeAndLeavesNftStaked() external {
        uint256 tokenId = _createAndStakeRewardingPosition();

        uint256 aliceCakeBefore = IERC20(CAKE).balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 claimed = stakingManager.claimRewards(tokenId, ALICE);

        assertGt(claimed, 0);
        assertEq(IERC20(CAKE).balanceOf(ALICE) - aliceCakeBefore, claimed);
        assertEq(stakingManager.tokenIdToGauge(tokenId), address(MASTER_CHEF));
        assertEq(NPM.ownerOf(tokenId), address(MASTER_CHEF));
    }

    function testUnstakeHarvestsCakeAndReturnsNftToVault() external {
        uint256 tokenId = _createAndStakeRewardingPosition();

        uint256 aliceCakeBefore = IERC20(CAKE).balanceOf(ALICE);
        vm.prank(ALICE);
        vault.unstakePosition(tokenId);

        assertEq(stakingManager.tokenIdToGauge(tokenId), address(0));
        assertEq(NPM.ownerOf(tokenId), address(vault));
        assertGt(IERC20(CAKE).balanceOf(ALICE), aliceCakeBefore);
    }

    function testCompoundRewardsKeepsNftInMasterChefAndIncreasesLiquidity() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 0.25 ether, 1_200e6);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);
        _accrueRewards(tokenId, 10 minutes);

        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(tokenId);
        assertEq(NPM.ownerOf(tokenId), address(MASTER_CHEF));

        vm.prank(ALICE);
        (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1) =
            stakingManager.compoundRewards(tokenId, 0, 5_000, block.timestamp + 1 hours);

        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(tokenId);
        assertGt(cakeAmount, 0);
        assertTrue(amountAdded0 != 0 || amountAdded1 != 0, "no compounded token amount");
        assertGt(liquidityAfter, liquidityBefore);
        assertEq(stakingManager.tokenIdToGauge(tokenId), address(MASTER_CHEF));
        assertEq(NPM.ownerOf(tokenId), address(MASTER_CHEF));
        (,,,,,, address user,) = MASTER_CHEF.userPositionInfos(tokenId);
        assertEq(user, address(stakingManager));
    }

    function testCompoundRewardsRefreshesMasterChefWithdrawTimelock() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 0.25 ether, 1_200e6);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);
        _accrueRewards(tokenId, 10 minutes);

        vm.prank(ALICE);
        stakingManager.compoundRewards(tokenId, 0, 5_000, block.timestamp + 1 hours);

        vm.expectRevert();
        vm.prank(ALICE);
        vault.unstakePosition(tokenId);

        _unlockMasterChef();

        vm.prank(ALICE);
        vault.unstakePosition(tokenId);

        assertEq(stakingManager.tokenIdToGauge(tokenId), address(0));
        assertEq(NPM.ownerOf(tokenId), address(vault));
    }

    function testDecreaseLiquidityAndCollectUnstakesThenRestakes() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);
        _unlockMasterChef();

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

        assertEq(stakingManager.tokenIdToGauge(tokenId), address(MASTER_CHEF));
        assertEq(NPM.ownerOf(tokenId), address(MASTER_CHEF));
        (,,,,,, address user,) = MASTER_CHEF.userPositionInfos(tokenId);
        assertEq(user, address(stakingManager));
    }

    function testRemoveAutoUnstakesPosition() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);
        _unlockMasterChef();

        vm.prank(ALICE);
        vault.remove(tokenId, ALICE, "");

        assertEq(stakingManager.tokenIdToGauge(tokenId), address(0));
        assertEq(NPM.ownerOf(tokenId), ALICE);
    }

    function testTransformWithRewardCompoundUnstakesAndRestakes() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        vm.startPrank(ALICE);
        vault.stakePosition(tokenId);
        vault.approveTransform(tokenId, address(noopTransformer), true);
        vm.stopPrank();
        _unlockMasterChef();

        // Direct reward compounding is covered separately. In transform flow, compounding a nonzero reward first would
        // refresh Pancake MasterChef's withdraw timelock and block the immediate unstake that transform performs.
        vm.prank(ALICE);
        stakingManager.claimRewards(tokenId, ALICE);

        vm.prank(ALICE);
        vault.transformWithRewardCompound(
            tokenId,
            address(noopTransformer),
            abi.encodeCall(NoopPancakeTransformer.execute, ()),
            IVault.RewardCompoundParams({minReward: 0, rewardSplitBps: 5_000, deadline: block.timestamp + 1 hours})
        );

        assertEq(stakingManager.tokenIdToGauge(tokenId), address(MASTER_CHEF));
        assertEq(NPM.ownerOf(tokenId), address(MASTER_CHEF));
        assertEq(vault.ownerOf(tokenId), ALICE);
    }

    function testLiquidationUnstakesPancakePositionBeforeCollectingCollateral() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = _min(collateralValue / 5, 2_000e6);
        assertGt(borrowAmount, 0);

        vm.prank(ALICE);
        vault.borrow(tokenId, borrowAmount);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);
        _unlockMasterChef();

        vault.setTokenConfig(WETH, 0, type(uint32).max);
        (,,, uint256 liquidationCost, uint256 liquidationValue) = vault.loanInfo(tokenId);
        assertGt(liquidationCost, 0);
        assertGt(liquidationValue, 0);

        deal(USDC, BOB, liquidationCost + 100e6);
        vm.startPrank(BOB);
        IERC20(USDC).approve(address(vault), liquidationCost + 100e6);
        vault.liquidate(
            IVault.LiquidateParams({
                tokenId: tokenId, amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 1 hours, recipient: BOB
            })
        );
        vm.stopPrank();

        assertEq(stakingManager.tokenIdToGauge(tokenId), address(0));
        assertEq(NPM.ownerOf(tokenId), address(vault));
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertEq(debtAfter, 0);
    }

    function testStakeRevertsForNonDepositor() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        vm.expectRevert(Constants.NotDepositor.selector);
        vm.prank(BOB);
        vault.stakePosition(tokenId);
    }

    function testUnstakeRevertsForUnauthorizedCaller() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(BOB);
        vault.unstakePosition(tokenId);
    }

    function testClaimRewardsRevertsForUnauthorizedCaller() external {
        uint256 tokenId = _createVaultedPosition(ALICE, 1 ether, 4_500e6);

        vm.prank(ALICE);
        vault.stakePosition(tokenId);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(BOB);
        stakingManager.claimRewards(tokenId, BOB);
    }

    function _assertLivePancakeConfig() internal {
        assertEq(address(NPM), MASTER_CHEF.nonfungiblePositionManager());
        assertEq(CAKE, MASTER_CHEF.CAKE());
        assertEq(NPM.factory(), address(FACTORY));
        assertEq(FACTORY.getPool(WETH, USDC, 500), address(WETH_USDC_POOL));
        assertEq(FACTORY.getPool(CAKE, WETH, 500), address(CAKE_WETH_POOL));
        assertEq(FACTORY.getPool(CAKE, USDC, 2500), address(CAKE_USDC_POOL));

        uint256 pid = MASTER_CHEF.v3PoolAddressPid(address(WETH_USDC_POOL));
        assertGt(pid, 0);
        (, IUniswapV3Pool configuredPool, address token0, address token1, uint24 fee,,) = MASTER_CHEF.poolInfo(pid);
        assertEq(address(configuredPool), address(WETH_USDC_POOL));
        assertEq(token0, WETH);
        assertEq(token1, USDC);
        assertEq(fee, 500);
    }

    function _createAndStakeRewardingPosition() internal returns (uint256 tokenId) {
        tokenId = _createVaultedPosition(ALICE, 2 ether, 9_000e6);
        vm.prank(ALICE);
        vault.stakePosition(tokenId);
        _accrueRewards(tokenId, 1 hours);
    }

    function _accrueRewards(uint256, uint256 elapsed) internal {
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + elapsed / 2);
    }

    function _unlockMasterChef() internal {
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
    }

    function _createVaultedPosition(address owner, uint256 wethAmount, uint256 usdcAmount)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _mintPancakePosition(owner, wethAmount, usdcAmount);
        vm.startPrank(owner);
        NPM.approve(address(vault), tokenId);
        vault.create(tokenId, owner);
        vm.stopPrank();
        assertEq(vault.ownerOf(tokenId), owner);
        assertEq(NPM.ownerOf(tokenId), address(vault));
    }

    function _mintPancakePosition(address owner, uint256 wethAmount, uint256 usdcAmount)
        internal
        returns (uint256 tokenId)
    {
        _fundLpOwner(owner, wethAmount, usdcAmount);

        int24 currentTick = _poolTick(WETH_USDC_POOL);
        int24 tickSpacing = WETH_USDC_POOL.tickSpacing();
        int24 centerTick = _floorToSpacing(currentTick, tickSpacing);
        int24 tickLower = centerTick - tickSpacing * 120;
        int24 tickUpper = centerTick + tickSpacing * 120;

        vm.startPrank(owner);
        IERC20(WETH).approve(address(NPM), wethAmount);
        IERC20(USDC).approve(address(NPM), usdcAmount);
        (tokenId,,,) = NPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: WETH,
                token1: USDC,
                fee: 500,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: wethAmount,
                amount1Desired: usdcAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: owner,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();

        assertEq(NPM.ownerOf(tokenId), owner);
        (,,,,,,, uint128 liquidity,,,,) = NPM.positions(tokenId);
        assertGt(liquidity, 0);
    }

    function _fundLpOwner(address owner, uint256 wethAmount, uint256 usdcAmount) internal {
        vm.deal(owner, wethAmount);
        vm.prank(owner);
        IWETH9(WETH).deposit{value: wethAmount}();
        deal(USDC, owner, usdcAmount);
    }

    function _seedVaultLiquidity(uint256 amount) internal {
        deal(USDC, LENDER, amount);
        vm.startPrank(LENDER);
        IERC20(USDC).approve(address(vault), amount);
        vault.deposit(amount, LENDER);
        vm.stopPrank();
    }

    function _floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--;
        }
        return compressed * tickSpacing;
    }

    function _poolTick(IUniswapV3Pool pool) internal view returns (int24 tick) {
        (bool success, bytes memory data) = address(pool).staticcall(abi.encodeWithSelector(pool.slot0.selector));
        require(success && data.length >= 64, "slot0 failed");

        uint256 word1;
        assembly ("memory-safe") {
            word1 := mload(add(data, 64))
            tick := signextend(2, word1)
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _baseRpc() internal returns (string memory rpcUrl) {
        try vm.envString("BASE_RPC_URL") returns (string memory url) {
            return url;
        } catch {
            return "https://mainnet.base.org";
        }
    }
}
