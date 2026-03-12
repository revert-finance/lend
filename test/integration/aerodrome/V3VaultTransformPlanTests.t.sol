// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";
import "../../../src/V3Vault.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";
import "./mocks/MockAerodromePositionManager.sol";
import "../../../lib/AggregatorV3Interface.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";

contract MockTokenIdMigrator {
    MockAerodromePositionManager public immutable npm;

    uint256 public tokenSequence;

    constructor(MockAerodromePositionManager _npm) {
        npm = _npm;
    }

    function migrate(uint256 tokenId) external {
        (,, address token0, address token1, uint24 tickSpacing, int24 tickLower, int24 tickUpper,,,,,) =
            npm.positions(tokenId);

        uint256 newTokenId = 1_000_000 + tokenSequence;
        tokenSequence++;

        npm.setPosition(newTokenId, token0, token1, int24(tickSpacing), tickLower, tickUpper, 1e18);
        npm.setTokensOwed(newTokenId, 0, 0);
        npm.mint(address(this), newTokenId);
        npm.safeTransferFrom(address(this), msg.sender, newTokenId);
    }
}

contract MockAutoRangeAndCompoundAerodromePositionManager is MockAerodromePositionManager {
    uint256 public tokenSequence;
    uint256 public lastMintedTokenId;

    constructor(address _factory, address _weth) MockAerodromePositionManager(_factory, _weth) {}

    function mint(MintParams calldata params)
        external
        payable
        override
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = 1_000_000 + tokenSequence;
        tokenSequence++;
        lastMintedTokenId = tokenId;

        _mint(params.recipient, tokenId);
        MockAerodromePositionManager(address(this))
            .setPosition(
                tokenId, params.token0, params.token1, int24(uint24(params.fee)), params.tickLower, params.tickUpper, 1
            );

        return (tokenId, 1, 0, 0);
    }
}

contract V3VaultTransformPlanTests is AerodromeTestBase {
    function setUp() public override {
        super.setUp();

        if (address(usdc) < address(dai)) {
            factory.setPool(address(usdc), address(dai), 500, usdcDaiPool);
        } else {
            factory.setPool(address(dai), address(usdc), 500, usdcDaiPool);
        }
    }

    function _deployAutoRange() internal returns (AutoRangeAndCompound) {
        AutoRangeAndCompound autoRange =
            new AutoRangeAndCompound(INonfungiblePositionManager(address(npm)), admin, admin, 60, 200, address(0), address(0));
        vault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vault));
        return autoRange;
    }

    function _configureAutoRangeAutoCompound(uint256 tokenId, AutoRangeAndCompound autoRange) internal {
        vm.prank(alice);
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
    }

    function testCreateFlowAllowsRawVaultDeposit() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);

        vm.prank(alice);
        npm.safeTransferFrom(alice, address(vault), tokenId);

        assertEq(vault.ownerOf(tokenId), alice);
    }

    function testTransformForStakedPositionUnstakesAndRestakes() public {
        AutoRangeAndCompound autoRange = _deployAutoRange();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);
        vm.prank(alice);
        vault.approveTransform(tokenId, address(autoRange), true);
        _configureAutoRangeAutoCompound(tokenId, autoRange);

        AutoRangeAndCompound.AutoCompoundParams memory params = AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });

        oracle.setMaxPoolPriceDifference(type(uint16).max);
        npm.setTokensOwed(tokenId, 0, 0);
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        vm.prank(admin);
        vault.transform(tokenId, address(autoRange), abi.encodeCall(AutoRangeAndCompound.autoCompound, (params)));

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));
    }

    function testTransformWithRewardCompoundCompoundsBeforeTransform() public {
        AutoRangeAndCompound autoRange = _deployAutoRange();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);
        vm.prank(alice);
        vault.approveTransform(tokenId, address(autoRange), true);
        _configureAutoRangeAutoCompound(tokenId, autoRange);

        AutoRangeAndCompound.AutoCompoundParams memory params = AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });

        usdcDaiGauge.setRewardRate(0);
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 7e18);
        npm.setTokensOwed(tokenId, 0, 0);
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        uint256 aliceAeroBefore = aero.balanceOf(alice);

        vm.prank(admin);
        uint256 transformedTokenId = vault.transformWithRewardCompound(
            tokenId,
            address(autoRange),
            abi.encodeCall(AutoRangeAndCompound.autoCompound, (params)),
            IVault.RewardCompoundParams({
                minAeroReward: 0,
                aeroSplitBps: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        assertEq(transformedTokenId, tokenId);
        assertEq(aero.balanceOf(alice), aliceAeroBefore);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));
    }

    function testTransformWithRewardCompoundSkipsWhenUnstaked() public {
        AutoRangeAndCompound autoRange = _deployAutoRange();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);
        _configureAutoRangeAutoCompound(tokenId, autoRange);

        AutoRangeAndCompound.AutoCompoundParams memory params = AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });

        npm.setTokensOwed(tokenId, 0, 0);
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        vm.prank(admin);
        uint256 transformedTokenId = vault.transformWithRewardCompound(
            tokenId,
            address(autoRange),
            abi.encodeCall(AutoRangeAndCompound.autoCompound, (params)),
            IVault.RewardCompoundParams({
                minAeroReward: 0,
                aeroSplitBps: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        assertEq(transformedTokenId, tokenId);
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testTransformWorksForUnstakedPosition() public {
        AutoRangeAndCompound autoRange = _deployAutoRange();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);
        _configureAutoRangeAutoCompound(tokenId, autoRange);

        AutoRangeAndCompound.AutoCompoundParams memory params = AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });

        oracle.setMaxPoolPriceDifference(type(uint16).max);
        npm.setTokensOwed(tokenId, 0, 0);

        vm.prank(admin);
        uint256 transformedTokenId =
            vault.transform(tokenId, address(autoRange), abi.encodeCall(AutoRangeAndCompound.autoCompound, (params)));

        assertEq(transformedTokenId, tokenId);
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testDebtZeroTransformCanRunThroughTransform() public {
        AutoRangeAndCompound autoRange = _deployAutoRange();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);
        _configureAutoRangeAutoCompound(tokenId, autoRange);

        AutoRangeAndCompound.AutoCompoundParams memory params = AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });

        oracle.setMaxPoolPriceDifference(type(uint16).max);
        npm.setTokensOwed(tokenId, 0, 0);

        vm.prank(admin);
        uint256 transformedTokenId =
            vault.transform(tokenId, address(autoRange), abi.encodeCall(AutoRangeAndCompound.autoCompound, (params)));

        assertEq(transformedTokenId, tokenId);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testTokenIdMigrationCanRestakeThroughTransform() public {
        MockTokenIdMigrator migrator = new MockTokenIdMigrator(npm);
        vault.setTransformer(address(migrator), true);

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);

        oracle.setMaxPoolPriceDifference(type(uint16).max);

        bytes memory transformData = abi.encodeWithSelector(MockTokenIdMigrator.migrate.selector, tokenId);

        vm.prank(admin);
        uint256 newTokenId = vault.transform(tokenId, address(migrator), transformData);

        assertTrue(newTokenId != tokenId);
        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(usdcDaiGauge));
        assertEq(vault.loans(tokenId), 0);
    }

    function testExecuteWithVaultCanRunUnstakedToStakedCycle() public {
        AutoRangeAndCompound autoRange = _deployAutoRange();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);
        vm.prank(alice);
        vault.approveTransform(tokenId, address(autoRange), true);
        _configureAutoRangeAutoCompound(tokenId, autoRange);

        AutoRangeAndCompound.AutoCompoundParams memory params = AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });

        npm.setTokensOwed(tokenId, 0, 0);
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        vm.prank(admin);
        autoRange.autoCompoundWithVault(params, address(vault));

        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }
}

contract V3VaultAutoRangeAndCompoundDebtZeroTests is AerodromeTestBase {
    function setUp() public override {
        super.setUp();

        npm = new MockAutoRangeAndCompoundAerodromePositionManager(address(factory), address(weth));
        oracle = new V3Oracle(npm, address(usdc), address(usdc));
        oracle.setTokenConfig(
            address(usdc),
            AggregatorV3Interface(address(usdcFeed)),
            3600,
            IUniswapV3Pool(usdcDaiPool),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            type(uint16).max
        );
        oracle.setTokenConfig(
            address(dai),
            AggregatorV3Interface(address(daiFeed)),
            3600,
            IUniswapV3Pool(usdcDaiPool),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            type(uint16).max
        );
        oracle.setTokenConfig(
            address(weth),
            AggregatorV3Interface(address(ethFeed)),
            3600,
            IUniswapV3Pool(wethUsdcPool),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            type(uint16).max
        );
        vault = new V3Vault("Revert Lend USDC", "rlUSDC", address(usdc), npm, irm, oracle);

        gaugeManager = new GaugeManager(
            IAerodromeNonfungiblePositionManager(address(npm)),
            IERC20(address(aero)),
            IVault(address(vault)),
            address(0),
            address(0)
        );

        usdcDaiGauge = new MockGauge(address(aero), address(npm));
        wethUsdcGauge = new MockGauge(address(aero), address(npm));

        MockPool(usdcDaiPool).setGauge(address(usdcDaiGauge));
        MockPool(wethUsdcPool).setGauge(address(wethUsdcGauge));

        gaugeManager.setGauge(address(usdcDaiPool), address(usdcDaiGauge));
        gaugeManager.setGauge(address(wethUsdcPool), address(wethUsdcGauge));
        if (address(usdc) < address(dai)) {
            factory.setPool(address(usdc), address(dai), 500, usdcDaiPool);
        } else {
            factory.setPool(address(dai), address(usdc), 500, usdcDaiPool);
        }
        vault.setGaugeManager(address(gaugeManager));

        aero.mint(address(usdcDaiGauge), 1000000e18);
        aero.mint(address(wethUsdcGauge), 1000000e18);

        uint32 cf90Percent = uint32(Q32 * 90 / 100);
        uint32 cf85Percent = uint32(Q32 * 85 / 100);
        vault.setTokenConfig(address(usdc), cf90Percent, type(uint32).max);
        vault.setTokenConfig(address(dai), cf90Percent, type(uint32).max);
        vault.setTokenConfig(address(weth), cf85Percent, type(uint32).max);
    }

    function _deployAutoRange() internal returns (AutoRangeAndCompound) {
        AutoRangeAndCompound autoRange =
            new AutoRangeAndCompound(INonfungiblePositionManager(address(npm)), admin, admin, 60, 200, address(0x1), address(0x2));

        vault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vault));

        return autoRange;
    }

    function testAutoRangeDebtZeroTransformCanRunThroughExecuteWithVault() public {
        AutoRangeAndCompound autoRange = _deployAutoRange();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);
        vm.prank(alice);
        vault.approveTransform(tokenId, address(autoRange), true);
        MockPool(usdcDaiPool).setTick(200);

        AutoRangeAndCompound.PositionConfig memory config = AutoRangeAndCompound.PositionConfig({
            lowerTickLimit: -1,
            upperTickLimit: 0,
            lowerTickDelta: -1,
            upperTickDelta: 1,
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            autoCompound: false,
            maxRewardX64: 0,
            autoCompoundMin0: 0,
            autoCompoundMin1: 0,
            autoCompoundRewardMin: 0
        });

        vm.prank(alice);
        autoRange.configToken(tokenId, address(vault), config);

        npm.setLiquidity(tokenId, 0);
        npm.setTokensOwed(tokenId, 0, 0);
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        AutoRangeAndCompound.ExecuteParams memory params = AutoRangeAndCompound.ExecuteParams({
            tokenId: tokenId,
            swap0To1: true,
            amountIn: 0,
            swapData: "",
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp + 1 hours,
            rewardX64: 0
        });

        vm.prank(admin);
        autoRange.executeWithVault(params, address(vault));

        MockAutoRangeAndCompoundAerodromePositionManager rangeNpm = MockAutoRangeAndCompoundAerodromePositionManager(address(npm));
        uint256 newTokenId = rangeNpm.lastMintedTokenId();

        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(usdcDaiGauge));
    }
}
