// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";

import "../../src/GaugeManager.sol";
import "../../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "../../src/interfaces/aerodrome/IGauge.sol";
import "../../src/utils/Constants.sol";

contract MockERC20Token is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSlipstreamFactory {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        pools[_key(tokenA, tokenB, tickSpacing)] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        return pools[_key(tokenA, tokenB, tickSpacing)];
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, int24(uint24(fee)))];
    }

    function _key(address tokenA, address tokenB, int24 tickSpacing) internal pure returns (bytes32) {
        return tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB, tickSpacing))
            : keccak256(abi.encode(tokenB, tokenA, tickSpacing));
    }
}

contract MockPool is IAerodromeSlipstreamPool {
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public immutable override tickSpacing;

    uint160 public sqrtPriceX96 = 79228162514264337593543950336;
    int24 public tick;
    int24 public observedTick;
    uint16 public observationIndex;
    uint16 public observationCardinality = 10;
    uint16 public observationCardinalityNext = 10;
    bool public unlocked = true;
    uint16 public outputBps = 10_000;

    uint256 public override feeGrowthGlobal0X128;
    uint256 public override feeGrowthGlobal1X128;
    address public override gauge;

    constructor(address tokenA, address tokenB, int24 _tickSpacing) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        tickSpacing = _tickSpacing;
        fee = uint24(uint256(uint24(_tickSpacing)));
    }

    function setGauge(address _gauge) external {
        gauge = _gauge;
    }

    function setOutputBps(uint16 _outputBps) external {
        outputBps = _outputBps;
    }

    function setTick(int24 _tick) external {
        tick = _tick;
    }

    function setObservedTick(int24 _tick) external {
        observedTick = _tick;
    }

    function slot0()
        external
        view
        override
        returns (
            uint160 sqrtPriceX96_,
            int24 tick_,
            uint16 observationIndex_,
            uint16 observationCardinality_,
            uint16 observationCardinalityNext_,
            bool unlocked_
        )
    {
        return (sqrtPriceX96, tick, observationIndex, observationCardinality, observationCardinalityNext, unlocked);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn = uint256(amountSpecified);
        uint256 amountOut = amountIn * outputBps / 10_000;

        if (zeroForOne) {
            IERC20(token1).transfer(recipient, amountOut);
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(int256(amountIn), -int256(amountOut), data);
            return (int256(amountIn), -int256(amountOut));
        }

        IERC20(token0).transfer(recipient, amountOut);
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(-int256(amountOut), int256(amountIn), data);
        return (-int256(amountOut), int256(amountIn));
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityPostWriteX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityPostWriteX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = int56(observedTick) * int56(uint56(secondsAgos[i]));
        }
    }

    function positions(bytes32)
        external
        pure
        override
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        return (liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1);
    }

    function observations(uint256)
        external
        pure
        override
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityPostWriteX128, bool initialized)
    {
        return (blockTimestamp, tickCumulative, secondsPerLiquidityPostWriteX128, initialized);
    }

    function ticks(int24)
        external
        pure
        override
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            int128 stakedLiquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            uint256 rewardGrowthOutsideX128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        )
    {
        return (
            liquidityGross,
            liquidityNet,
            stakedLiquidityNet,
            feeGrowthOutside0X128,
            feeGrowthOutside1X128,
            rewardGrowthOutsideX128,
            tickCumulativeOutside,
            secondsPerLiquidityOutsideX128,
            secondsOutside,
            initialized
        );
    }
}

contract MockVault is IERC721Receiver {
    mapping(uint256 => address) public owners;

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract MockNPM is ERC721 {
    struct Position {
        address token0;
        address token1;
        uint24 feeOrTickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    address public immutable factory;
    address public immutable WETH9;

    mapping(uint256 => Position) internal positionData;

    uint256 public nextAdded0;
    uint256 public nextAdded1;

    constructor(address _factory, address _weth) ERC721("Mock NPM", "MNPM") {
        factory = _factory;
        WETH9 = _weth;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function setPosition(
        uint256 tokenId,
        address tokenA,
        address tokenB,
        uint24 feeOrTickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        positionData[tokenId] = Position(token0, token1, feeOrTickSpacing, tickLower, tickUpper, liquidity);
    }

    function setNextIncreaseLiquidityResult(uint256 amount0, uint256 amount1) external {
        nextAdded0 = amount0;
        nextAdded1 = amount1;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        Position memory position = positionData[tokenId];
        return (
            0,
            address(0),
            position.token0,
            position.token1,
            position.feeOrTickSpacing,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            0,
            0,
            0,
            0
        );
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage position = positionData[params.tokenId];
        amount0 = nextAdded0 == 0 ? params.amount0Desired : Math.min(params.amount0Desired, nextAdded0);
        amount1 = nextAdded1 == 0 ? params.amount1Desired : Math.min(params.amount1Desired, nextAdded1);

        if (amount0 != 0) {
            IERC20(position.token0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 != 0) {
            IERC20(position.token1).transferFrom(msg.sender, address(this), amount1);
        }

        nextAdded0 = 0;
        nextAdded1 = 0;
        liquidity = amount0 + amount1 == 0 ? 0 : 1;
        position.liquidity += liquidity;
    }
}

contract MockGauge is IGauge {
    IERC721 public immutable nft;
    IERC20 public immutable rewardToken;

    mapping(uint256 => address) public staker;
    mapping(uint256 => uint256) public rewardPerTokenId;
    bool public revertOnGetReward;
    address public payoutToken0;
    address public payoutToken1;
    uint256 public depositPayout0;
    uint256 public depositPayout1;
    uint256 public withdrawPayout0;
    uint256 public withdrawPayout1;

    constructor(IERC721 _nft, IERC20 _rewardToken) {
        nft = _nft;
        rewardToken = _rewardToken;
    }

    function setReward(uint256 tokenId, uint256 amount) external {
        rewardPerTokenId[tokenId] = amount;
    }

    function setRevertOnGetReward(bool value) external {
        revertOnGetReward = value;
    }

    function setPayoutConfig(
        address _payoutToken0,
        address _payoutToken1,
        uint256 _depositPayout0,
        uint256 _depositPayout1,
        uint256 _withdrawPayout0,
        uint256 _withdrawPayout1
    ) external {
        payoutToken0 = _payoutToken0;
        payoutToken1 = _payoutToken1;
        depositPayout0 = _depositPayout0;
        depositPayout1 = _depositPayout1;
        withdrawPayout0 = _withdrawPayout0;
        withdrawPayout1 = _withdrawPayout1;
    }

    function deposit(uint256 tokenId) external override {
        nft.transferFrom(msg.sender, address(this), tokenId);
        if (depositPayout0 != 0) {
            IERC20(payoutToken0).transfer(msg.sender, depositPayout0);
        }
        if (depositPayout1 != 0) {
            IERC20(payoutToken1).transfer(msg.sender, depositPayout1);
        }
        staker[tokenId] = msg.sender;
    }

    function withdraw(uint256 tokenId) external override {
        if (staker[tokenId] != msg.sender) {
            revert("not staker");
        }

        if (withdrawPayout0 != 0) {
            IERC20(payoutToken0).transfer(msg.sender, withdrawPayout0);
        }
        if (withdrawPayout1 != 0) {
            IERC20(payoutToken1).transfer(msg.sender, withdrawPayout1);
        }

        delete staker[tokenId];
        nft.transferFrom(address(this), msg.sender, tokenId);
    }

    function getReward(uint256 tokenId) external override {
        if (revertOnGetReward) {
            revert("reward revert");
        }
        if (staker[tokenId] == address(0)) {
            revert("not staked");
        }

        uint256 reward = rewardPerTokenId[tokenId];
        rewardPerTokenId[tokenId] = 0;
        if (reward != 0) {
            rewardToken.transfer(msg.sender, reward);
        }
    }
}

contract GaugeManagerUnitTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    address internal constant ALICE = address(0xA11CE);
    address internal constant RECIPIENT = address(0xBEEF);

    MockERC20Token internal aero;
    MockERC20Token internal usdc;
    MockERC20Token internal dai;
    MockERC20Token internal weth;
    MockSlipstreamFactory internal factory;
    MockPool internal usdcDaiPool;
    MockPool internal aeroUsdcPool;
    MockPool internal aeroWethPool;
    MockNPM internal npm;
    MockGauge internal gauge;
    MockVault internal vault;
    GaugeManager internal gaugeManager;

    function setUp() external {
        aero = new MockERC20Token("AERO", "AERO");
        usdc = new MockERC20Token("USDC", "USDC");
        dai = new MockERC20Token("DAI", "DAI");
        weth = new MockERC20Token("WETH", "WETH");

        factory = new MockSlipstreamFactory();
        usdcDaiPool = new MockPool(address(usdc), address(dai), 100);
        aeroUsdcPool = new MockPool(address(aero), address(usdc), 200);
        aeroWethPool = new MockPool(address(aero), address(weth), 200);

        npm = new MockNPM(address(factory), address(weth));
        gauge = new MockGauge(IERC721(address(npm)), IERC20(address(aero)));
        vault = new MockVault();

        usdcDaiPool.setGauge(address(gauge));

        factory.setPool(address(usdc), address(dai), 100, address(usdcDaiPool));
        factory.setPool(address(aero), address(usdc), 200, address(aeroUsdcPool));
        factory.setPool(address(aero), address(weth), 200, address(aeroWethPool));

        gaugeManager = new GaugeManager(
            INonfungiblePositionManager(address(npm)), IERC20(address(aero)), IVault(address(vault)), address(0), address(0)
        );

        gaugeManager.setGauge(address(usdcDaiPool), address(gauge));
        gaugeManager.setRewardBasePool(address(usdc), address(aeroUsdcPool));
        gaugeManager.setRewardBasePool(address(weth), address(aeroWethPool));

        npm.setPosition(TOKEN_ID, address(usdc), address(dai), 100, -60, 60, 10);
        npm.mint(address(vault), TOKEN_ID);
        vault.setOwner(TOKEN_ID, ALICE);

        vm.prank(address(vault));
        npm.approve(address(gaugeManager), TOKEN_ID);

        // Pre-fund pools with output tokens for swaps.
        usdc.mint(address(aeroUsdcPool), 1_000_000 ether);
        aero.mint(address(aeroUsdcPool), 1_000_000 ether);
        dai.mint(address(usdcDaiPool), 1_000_000 ether);
        usdc.mint(address(usdcDaiPool), 1_000_000 ether);
        weth.mint(address(aeroWethPool), 1_000_000 ether);
        aero.mint(address(aeroWethPool), 1_000_000 ether);
    }

    function testClaimRewardsFromVault() external {
        _stake();

        aero.mint(address(gauge), 10 ether);
        gauge.setReward(TOKEN_ID, 10 ether);

        vm.prank(address(vault));
        uint256 claimed = gaugeManager.claimRewards(TOKEN_ID, RECIPIENT);

        assertEq(claimed, 10 ether);
        assertEq(aero.balanceOf(RECIPIENT), 10 ether);
    }

    function testStakeForwardsCollectedPairFeesToOwner() external {
        gauge.setPayoutConfig(address(usdc), address(dai), 7 ether, 11 ether, 0, 0);
        usdc.mint(address(gauge), 7 ether);
        dai.mint(address(gauge), 11 ether);

        vm.prank(address(vault));
        gaugeManager.stakePosition(TOKEN_ID);

        assertEq(usdc.balanceOf(ALICE), 7 ether);
        assertEq(dai.balanceOf(ALICE), 11 ether);
        assertEq(usdc.balanceOf(address(gaugeManager)), 0);
        assertEq(dai.balanceOf(address(gaugeManager)), 0);
    }

    function testUnstakeSucceedsWhenRewardClaimReverts() external {
        _stake();
        gauge.setRevertOnGetReward(true);

        vm.prank(address(vault));
        gaugeManager.unstakePosition(TOKEN_ID);

        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(0));
        assertEq(npm.ownerOf(TOKEN_ID), address(vault));
    }

    function testCompoundRewardsUsesFixedPoolsAndSendsLeftovers() external {
        _stake();

        aero.mint(address(gauge), 100 ether);
        gauge.setReward(TOKEN_ID, 100 ether);
        npm.setNextIncreaseLiquidityResult(30 ether, 40 ether);

        vm.prank(address(vault));
        (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) =
            gaugeManager.compoundRewards(TOKEN_ID, 0, 4_000, block.timestamp + 1);

        uint256 rewardX64 = gaugeManager.totalRewardX64();
        uint256 q64 = 2 ** 64;
        uint256 rewardAmount0 = amountAdded0 * rewardX64 / q64;
        uint256 rewardAmount1 = amountAdded1 * rewardX64 / q64;

        assertEq(aeroAmount, 100 ether);
        assertEq(amountAdded0, 30 ether);
        assertEq(amountAdded1, 40 ether);
        assertEq(usdc.balanceOf(ALICE), 40 ether - amountAdded0 - rewardAmount0);
        assertEq(dai.balanceOf(ALICE), 60 ether - amountAdded1 - rewardAmount1);
        assertEq(usdc.balanceOf(address(gaugeManager)), rewardAmount0);
        assertEq(dai.balanceOf(address(gaugeManager)), rewardAmount1);
        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(gauge));
        assertEq(npm.ownerOf(TOKEN_ID), address(gauge));
    }

    function testCompoundRewardsForwardsDepositRealizedFeesToOwner() external {
        _stake();

        // USDC routes directly through AERO/USDC; DAI routes through the position pool (USDC/DAI).
        gauge.setPayoutConfig(address(usdc), address(dai), 7 ether, 11 ether, 0, 0);
        usdc.mint(address(gauge), 7 ether);
        dai.mint(address(gauge), 11 ether);

        aero.mint(address(gauge), 100 ether);
        gauge.setReward(TOKEN_ID, 100 ether);
        npm.setNextIncreaseLiquidityResult(30 ether, 40 ether);

        vm.prank(address(vault));
        (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) =
            gaugeManager.compoundRewards(TOKEN_ID, 0, 4_000, block.timestamp + 1);

        uint256 rewardX64 = gaugeManager.totalRewardX64();
        uint256 q64 = 2 ** 64;
        uint256 rewardAmount0 = amountAdded0 * rewardX64 / q64;
        uint256 rewardAmount1 = amountAdded1 * rewardX64 / q64;

        assertEq(aeroAmount, 100 ether);
        assertEq(amountAdded0, 30 ether);
        assertEq(amountAdded1, 40 ether);
        assertEq(usdc.balanceOf(ALICE), 7 ether + 40 ether - amountAdded0 - rewardAmount0);
        assertEq(dai.balanceOf(ALICE), 11 ether + 60 ether - amountAdded1 - rewardAmount1);
        assertEq(usdc.balanceOf(address(gaugeManager)), rewardAmount0);
        assertEq(dai.balanceOf(address(gaugeManager)), rewardAmount1);
    }

    function testCompoundRewardsUsesDirectRouteWhenTargetHasConfiguredBasePool() external {
        uint256 tokenId = 2;
        npm.setPosition(tokenId, address(usdc), address(weth), 100, -60, 60, 10);
        npm.mint(address(vault), tokenId);
        vault.setOwner(tokenId, ALICE);

        MockPool usdcWethPool = new MockPool(address(usdc), address(weth), 100);
        usdcWethPool.setGauge(address(gauge));
        factory.setPool(address(usdc), address(weth), 100, address(usdcWethPool));
        gaugeManager.setGauge(address(usdcWethPool), address(gauge));
        usdc.mint(address(usdcWethPool), 1_000_000 ether);
        weth.mint(address(usdcWethPool), 1_000_000 ether);

        vm.prank(address(vault));
        npm.approve(address(gaugeManager), tokenId);
        vm.prank(address(vault));
        gaugeManager.stakePosition(tokenId);

        aero.mint(address(gauge), 50 ether);
        gauge.setReward(tokenId, 50 ether);

        vm.prank(ALICE);
        (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) =
            gaugeManager.compoundRewards(tokenId, 0, 5_000, block.timestamp + 1);

        assertEq(aeroAmount, 50 ether);
        assertGt(amountAdded0, 0);
        assertGt(amountAdded1, 0);
    }

    function testCompoundRewardsRevertsWhenRouteMissing() external {
        _stake();
        gaugeManager.setRewardBasePool(address(usdc), address(0));

        aero.mint(address(gauge), 10 ether);
        gauge.setReward(TOKEN_ID, 10 ether);

        vm.prank(address(vault));
        vm.expectRevert(Constants.NotConfigured.selector);
        gaugeManager.compoundRewards(TOKEN_ID, 0, 5_000, block.timestamp + 1);
    }

    function testCompoundRewardsRevertsWhenRoutePoolFailsTwapCheck() external {
        _stake();
        aeroUsdcPool.setTick(500);
        aeroUsdcPool.setObservedTick(0);

        aero.mint(address(gauge), 10 ether);
        gauge.setReward(TOKEN_ID, 10 ether);

        vm.prank(address(vault));
        vm.expectRevert(Constants.TWAPCheckFailed.selector);
        gaugeManager.compoundRewards(TOKEN_ID, 0, 10_000, block.timestamp + 1);
    }

    function testCompoundRewardsRevertsWhenRoutePoolOutputFallsBelowValidatedMinimum() external {
        _stake();
        aeroUsdcPool.setTick(0);
        aeroUsdcPool.setObservedTick(0);
        aeroUsdcPool.setOutputBps(9_700);

        aero.mint(address(gauge), 10 ether);
        gauge.setReward(TOKEN_ID, 10 ether);

        vm.prank(address(vault));
        vm.expectRevert(Constants.SlippageError.selector);
        gaugeManager.compoundRewards(TOKEN_ID, 0, 10_000, block.timestamp + 1);
    }

    function testCompoundRewardsRevertsOnInvalidSplit() external {
        _stake();

        vm.prank(address(vault));
        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.compoundRewards(TOKEN_ID, 0, 10_001, block.timestamp + 1);
    }

    function testCompoundRewardsReturnsZeroWhenNoRewards() external {
        _stake();

        vm.prank(address(vault));
        (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) =
            gaugeManager.compoundRewards(TOKEN_ID, 0, 0, block.timestamp + 1);

        assertEq(aeroAmount, 0);
        assertEq(amountAdded0, 0);
        assertEq(amountAdded1, 0);
        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(gauge));
    }

    function testCompoundRewardsRevertsWhenClaimedRewardBelowMinimum() external {
        _stake();

        vm.prank(address(vault));
        vm.expectRevert(Constants.NotEnoughReward.selector);
        gaugeManager.compoundRewards(TOKEN_ID, 1, 0, block.timestamp + 1);
    }

    function testSetRewardBasePoolValidatesPair() external {
        MockPool wrongPool = new MockPool(address(usdc), address(dai), 200);

        vm.expectRevert(Constants.InvalidPool.selector);
        gaugeManager.setRewardBasePool(address(usdc), address(wrongPool));
    }

    function testCompoundRewardsRevertsWhenCallerIsNotVaultOrOwner() external {
        _stake();

        vm.prank(RECIPIENT);
        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.compoundRewards(TOKEN_ID, 0, 0, block.timestamp + 1);
    }

    function testWithdrawBalancesOnlyAllowedForWithdrawer() external {
        usdc.mint(address(gaugeManager), 7 ether);
        dai.mint(address(gaugeManager), 11 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);

        vm.prank(ALICE);
        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.withdrawBalances(tokens, ALICE);

        gaugeManager.setWithdrawer(RECIPIENT);
        vm.prank(RECIPIENT);
        gaugeManager.withdrawBalances(tokens, ALICE);

        assertEq(usdc.balanceOf(ALICE), 7 ether);
        assertEq(dai.balanceOf(ALICE), 11 ether);
    }

    function _stake() internal {
        vm.prank(address(vault));
        gaugeManager.stakePosition(TOKEN_ID);
        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(gauge));
        assertEq(npm.ownerOf(TOKEN_ID), address(gauge));
    }
}
