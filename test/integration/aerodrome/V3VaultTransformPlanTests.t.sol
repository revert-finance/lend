// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";
import "../../../src/V3Vault.sol";
import "../../../src/transformers/AutoCompound.sol";
import "../../../src/transformers/AutoRange.sol";
import "./mocks/MockAerodromePositionManager.sol";
import "v3-periphery-patched/interfaces/INonfungiblePositionManager.sol";

contract MockTokenIdMigrator {
    MockAerodromePositionManager public immutable npm;

    uint256 public tokenSequence;

    constructor(MockAerodromePositionManager _npm) {
        npm = _npm;
    }

    function migrate(uint256 tokenId) external {
        (
            ,, address token0, address token1, uint24 tickSpacing, int24 tickLower, int24 tickUpper,,,,,
        ) = npm.positions(tokenId);

        uint256 newTokenId = 1_000_000 + tokenSequence;
        tokenSequence++;

        npm.setPosition(newTokenId, token0, token1, int24(tickSpacing), tickLower, tickUpper, 1e18);
        npm.setTokensOwed(newTokenId, 0, 0);
        npm.mint(address(this), newTokenId);
        npm.safeTransferFrom(address(this), msg.sender, newTokenId);
    }
}

contract MockPermitAerodromePositionManager is MockAerodromePositionManager {
    constructor(address _factory, address _weth) MockAerodromePositionManager(_factory, _weth) {}

    function permit(address spender, uint256 tokenId, uint256, uint8, bytes32, bytes32) external payable override {
        _approve(spender, tokenId);
    }
}

contract MockAutoRangeAerodromePositionManager is MockAerodromePositionManager {
    uint256 public tokenSequence;
    uint256 public lastMintedTokenId;

    constructor(address _factory, address _weth) MockAerodromePositionManager(_factory, _weth) {}

    function mint(MintParams calldata params) external payable override
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = 1_000_000 + tokenSequence;
        tokenSequence++;
        lastMintedTokenId = tokenId;

        _mint(params.recipient, tokenId);
        MockAerodromePositionManager(address(this)).setPosition(
            tokenId,
            params.token0,
            params.token1,
            int24(uint24(params.fee)),
            params.tickLower,
            params.tickUpper,
            1
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

    function _deployAutoCompound() internal returns (AutoCompound) {
        AutoCompound autoCompound = new AutoCompound(
            INonfungiblePositionManager(address(npm)),
            admin,
            admin,
            60,
            200,
            address(0x1),
            address(0x2),
            address(aero)
        );
        vault.setTransformer(address(autoCompound), true);
        autoCompound.setVault(address(vault));
        return autoCompound;
    }

    function testCreateFlowOnlyRejectsRawVaultDeposit() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);

        vm.expectRevert(V3Vault.UnexpectedDeposit.selector);
        vm.prank(alice);
        npm.safeTransferFrom(alice, address(vault), tokenId);

        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);

        assertEq(vault.ownerOf(tokenId), alice);
    }

    function testTransformRevertsForStakedPosition() public {
        AutoCompound autoCompound = _deployAutoCompound();

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
        vault.approveTransform(tokenId, address(autoCompound), true);

        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(V3Vault.PositionIsStaked.selector);
        vm.prank(admin);
        vault.transform(tokenId, address(autoCompound), abi.encodeCall(AutoCompound.execute, (params)));

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testUnstakeTransformStakeWorksForUnstakedPosition() public {
        AutoCompound autoCompound = _deployAutoCompound();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);

        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1 hours
        });

        npm.setTokensOwed(tokenId, 0, 0);

        vm.prank(admin);
        uint256 transformedTokenId = vault.unstakeTransformStake(tokenId, address(autoCompound), abi.encodeCall(AutoCompound.execute, (params)));

        assertEq(transformedTokenId, tokenId);
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testDebtZeroTransformCanRunThroughUnstakeTransformStake() public {
        AutoCompound autoCompound = _deployAutoCompound();

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);
        vm.prank(alice);
        vault.approveTransform(tokenId, admin, true);

        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1 hours
        });

        oracle.setMaxPoolPriceDifference(0);
        npm.setTokensOwed(tokenId, 0, 0);

        vm.prank(admin);
        uint256 transformedTokenId = vault.unstakeTransformStake(tokenId, address(autoCompound), abi.encodeCall(AutoCompound.execute, (params)));

        assertEq(transformedTokenId, tokenId);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testTokenIdMigrationCanRestakeThroughWrapper() public {
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

        oracle.setMaxPoolPriceDifference(0);

        bytes memory transformData = abi.encodeWithSelector(MockTokenIdMigrator.migrate.selector, tokenId);

        vm.prank(admin);
        uint256 newTokenId = vault.unstakeTransformStake(tokenId, address(migrator), transformData);

        assertTrue(newTokenId != tokenId);
        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(usdcDaiGauge));
        assertEq(vault.loans(tokenId), 0);
    }

    function testExecuteWithVaultCanRunUnstakedToStakedCycle() public {
        AutoCompound autoCompound = _deployAutoCompound();

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
        vault.approveTransform(tokenId, address(autoCompound), true);

        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1 hours
        });

        npm.setTokensOwed(tokenId, 0, 0);
        oracle.setMaxPoolPriceDifference(0);

        vm.prank(admin);
        autoCompound.executeWithVault(params, address(vault));

        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }
}

contract V3VaultCreateWithPermitTests is AerodromeTestBase {
    function setUp() public override {
        super.setUp();

        npm = new MockPermitAerodromePositionManager(address(factory), address(weth));
        oracle = new V3Oracle(npm, address(usdc), address(usdc));
        vault = new V3Vault(
            "Revert Lend USDC",
            "rlUSDC",
            address(usdc),
            npm,
            irm,
            oracle
        );
    }

    function testCreateWithPermitFlow() public {
        uint256 tokenId = createPosition(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            1000e18
        );

        vm.prank(alice);
        vault.createWithPermit(tokenId, alice, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));

        assertEq(vault.ownerOf(tokenId), alice);
    }
}

contract V3VaultAutoRangeDebtZeroTests is AerodromeTestBase {
    function setUp() public override {
        super.setUp();

        npm = new MockAutoRangeAerodromePositionManager(address(factory), address(weth));
        oracle = new V3Oracle(npm, address(usdc), address(usdc));
        vault = new V3Vault(
            "Revert Lend USDC",
            "rlUSDC",
            address(usdc),
            npm,
            irm,
            oracle
        );

        gaugeManager = new GaugeManager(
            IAerodromeNonfungiblePositionManager(address(npm)),
            IERC20(address(aero)),
            IVault(address(vault)),
            address(0),
            address(0),
            admin
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

    function _deployAutoRange() internal returns (AutoRange) {
        AutoRange autoRange = new AutoRange(
            INonfungiblePositionManager(address(npm)),
            admin,
            admin,
            60,
            200,
            address(0x1),
            address(0x2)
        );

        vault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vault));

        return autoRange;
    }

    function testAutoRangeDebtZeroTransformCanRunThroughExecuteWithVault() public {
        AutoRange autoRange = _deployAutoRange();

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

        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: -1,
            upperTickLimit: 0,
            lowerTickDelta: -1,
            upperTickDelta: 1,
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            autoCompound: false,
            maxRewardX64: 0
        });

        vm.prank(alice);
        autoRange.configToken(tokenId, address(vault), config);

        npm.setLiquidity(tokenId, 0);
        npm.setTokensOwed(tokenId, 0, 0);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
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

        MockAutoRangeAerodromePositionManager rangeNpm = MockAutoRangeAerodromePositionManager(address(npm));
        uint256 newTokenId = rangeNpm.lastMintedTokenId();

        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(usdcDaiGauge));
    }
}
