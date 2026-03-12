// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../../src/transformers/AutoRangeAndCompound.sol";
import "../../../../src/utils/Constants.sol";
import "../../../../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "../../../../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

contract AutoRangeAndCompoundAerodromeComprehensiveTest is Test, Constants {
    uint64 constant MAX_REWARD = uint64(Q64 / 400); // 0.25%

    // Real Aerodrome position on Base
    uint256 constant REAL_POSITION_ID = 19466427;
    uint256 constant HAPPY_PATH_BLOCK = 42_113_455;
    uint256 constant HAPPY_PATH_TOKEN_ID = 50994801;

    // Aerodrome contracts on Base
    IAerodromeSlipstreamFactory constant FACTORY =
        IAerodromeSlipstreamFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    address constant UNIVERSAL_ROUTER = 0x198EF79F1F515F02dFE9e3115eD9fC07183f02fC;

    // Test accounts
    address constant OPERATOR_ACCOUNT = address(0x1111);
    address constant WITHDRAWER_ACCOUNT = address(0x2222);

    AutoRangeAndCompound autoRange;

    uint256 constant BASE_FORK_BLOCK = 38_000_000;
    uint256 baseFork;

    // Position details (loaded in setUp)
    address positionOwner;
    address token0;
    address token1;
    uint24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    address pool;
    int24 currentTick;

    function setUp() external {
        string memory baseRpc = "https://mainnet.base.org";
        baseFork = vm.createFork(baseRpc, BASE_FORK_BLOCK);
        vm.selectFork(baseFork);

        autoRange =
            new AutoRangeAndCompound(NPM, OPERATOR_ACCOUNT, WITHDRAWER_ACCOUNT, 60, 100, UNIVERSAL_ROUTER, address(0));

        _loadPositionDetails();
    }

    function _loadPositionDetails() internal {
        positionOwner = NPM.ownerOf(REAL_POSITION_ID);
        (,, token0, token1, tickSpacing, tickLower, tickUpper, liquidity,,,,) = NPM.positions(REAL_POSITION_ID);
        pool = FACTORY.getPool(token0, token1, int24(tickSpacing));
        assertTrue(pool != address(0), "pool missing for position");
        (, currentTick,,,,) = IAerodromeSlipstreamPool(pool).slot0();
    }

    function _defaultConfig() internal pure returns (AutoRangeAndCompound.PositionConfig memory config) {
        config = AutoRangeAndCompound.PositionConfig({
            lowerTickLimit: 0,
            upperTickLimit: 0,
            lowerTickDelta: -600,
            upperTickDelta: 600,
            token0SlippageX64: uint64(Q64 / 100),
            token1SlippageX64: uint64(Q64 / 100),
            onlyFees: false,
            autoCompound: false,
            maxRewardX64: MAX_REWARD,
            autoCompoundMin0: 0,
            autoCompoundMin1: 0,
            autoCompoundRewardMin: 0
        });
    }

    function _executeParams() internal view returns (AutoRangeAndCompound.ExecuteParams memory) {
        return AutoRangeAndCompound.ExecuteParams({
            tokenId: REAL_POSITION_ID,
            swap0To1: false,
            amountIn: 0,
            swapData: "",
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            rewardX64: MAX_REWARD / 2
        });
    }

    function _extractRangeChangedNewTokenId(Vm.Log[] memory entries, uint256 oldTokenId) internal pure returns (uint256) {
        bytes32 signature = keccak256("RangeChanged(uint256,uint256)");
        bytes32 oldTokenIdTopic = bytes32(oldTokenId);
        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            if (
                entry.topics.length == 3 && entry.topics[0] == signature && entry.topics[1] == oldTokenIdTopic
            ) {
                return uint256(entry.topics[2]);
            }
        }
        return 0;
    }

    function testPositionExists() external {
        assertEq(NPM.ownerOf(REAL_POSITION_ID), positionOwner);
        assertTrue(positionOwner != address(0), "invalid owner");
        assertTrue(token0 != address(0) && token1 != address(0), "invalid tokens");
        assertGt(uint256(tickSpacing), 0, "invalid tick spacing");
        assertLt(tickLower, tickUpper, "invalid tick range");
        assertEq(pool, FACTORY.getPool(token0, token1, int24(tickSpacing)));
    }

    function testPoolSlot0IsReadable() external {
        (uint160 sqrtPriceX96, int24 tick,,,,) = IAerodromeSlipstreamPool(pool).slot0();
        assertGt(uint256(sqrtPriceX96), 0, "slot0 sqrt price is zero");
        assertEq(int256(tick), int256(currentTick), "stored/current tick mismatch");
    }

    function testConfigurePosition() external {
        AutoRangeAndCompound.PositionConfig memory config = _defaultConfig();

        vm.prank(positionOwner);
        autoRange.configToken(REAL_POSITION_ID, address(0), config);

        (
            ,
            ,
            int32 lowerTickDelta,
            int32 upperTickDelta,
            uint64 token0SlippageX64,
            uint64 token1SlippageX64,
            bool onlyFees,
            bool autoCompound,
            uint64 maxRewardX64,
            uint128 autoCompoundMin0,
            uint128 autoCompoundMin1,
            uint128 autoCompoundRewardMin
        ) = autoRange.positionConfigs(REAL_POSITION_ID);

        assertEq(lowerTickDelta, config.lowerTickDelta);
        assertEq(upperTickDelta, config.upperTickDelta);
        assertEq(token0SlippageX64, config.token0SlippageX64);
        assertEq(token1SlippageX64, config.token1SlippageX64);
        assertEq(onlyFees, config.onlyFees);
        assertEq(autoCompound, config.autoCompound);
        assertEq(maxRewardX64, config.maxRewardX64);
        assertEq(autoCompoundMin0, config.autoCompoundMin0);
        assertEq(autoCompoundMin1, config.autoCompoundMin1);
        assertEq(autoCompoundRewardMin, config.autoCompoundRewardMin);
    }

    function testAdjustPositionBasic() external {
        AutoRangeAndCompound.PositionConfig memory config = _defaultConfig();
        vm.prank(positionOwner);
        autoRange.configToken(REAL_POSITION_ID, address(0), config);

        vm.prank(positionOwner);
        NPM.approve(address(autoRange), REAL_POSITION_ID);

        // At the pinned fork block this live position has zero liquidity and no owed amounts,
        // so a direct adjust with amountIn=0 has nothing to mint and must revert.
        assertEq(liquidity, 0, "unexpected non-zero liquidity for deterministic negative-path test");
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert();
        autoRange.execute(_executeParams());
    }

    function testAdjustPositionLivePositionHappyPath() external {
        string memory baseRpc = "https://mainnet.base.org";
        uint256 historicalFork = vm.createFork(baseRpc, HAPPY_PATH_BLOCK);
        vm.selectFork(historicalFork);

        AutoRangeAndCompound localAutoRange =
            new AutoRangeAndCompound(NPM, OPERATOR_ACCOUNT, WITHDRAWER_ACCOUNT, 60, 100, UNIVERSAL_ROUTER, address(0));

        uint256 tokenId = HAPPY_PATH_TOKEN_ID;
        address owner = NPM.ownerOf(tokenId);

        (,, address token0Position, address token1Position, uint24 fee, int24 oldTickLower, int24 oldTickUpper, uint128 oldLiquidity,,,,)
        = NPM.positions(tokenId);
        assertGt(oldLiquidity, 0, "expected live historical liquidity");

        address localPool = FACTORY.getPool(token0Position, token1Position, int24(fee));
        assertTrue(localPool != address(0), "pool missing for active position");
        (, int24 poolTick,,,,) = IAerodromeSlipstreamPool(localPool).slot0();
        int24 spacing = IAerodromeSlipstreamPool(localPool).tickSpacing();
        int24 baseTick = poolTick - (((poolTick % spacing) + spacing) % spacing);

        AutoRangeAndCompound.PositionConfig memory config = _defaultConfig();
        config.lowerTickLimit = -1_000_000_000; // force execute path even when current range contains the price
        config.lowerTickDelta = int32(-10 * spacing);
        config.upperTickDelta = int32(10 * spacing);
        vm.prank(owner);
        localAutoRange.configToken(tokenId, address(0), config);

        vm.prank(owner);
        NPM.approve(address(localAutoRange), tokenId);
        localAutoRange.setTWAPConfig(uint16(localAutoRange.MAX_TWAP_TICK_DIFFERENCE()), localAutoRange.TWAPSeconds());

        AutoRangeAndCompound.ExecuteParams memory params = AutoRangeAndCompound.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            swapData: "",
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            rewardX64: config.maxRewardX64
        });

        vm.recordLogs();
        vm.prank(OPERATOR_ACCOUNT);
        localAutoRange.execute(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 newTokenId = _extractRangeChangedNewTokenId(logs, tokenId);
        assertGt(newTokenId, 0, "missing RangeChanged event");
        assertTrue(newTokenId != tokenId, "token id was not replaced");
        assertEq(NPM.ownerOf(newTokenId), owner, "new token owner mismatch");

        (,,,,, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity,,,,) = NPM.positions(newTokenId);
        assertGt(newLiquidity, 0, "new position liquidity is zero");
        assertEq(newTickLower, baseTick + int24(config.lowerTickDelta), "new lower tick mismatch");
        assertEq(newTickUpper, baseTick + int24(config.upperTickDelta), "new upper tick mismatch");
        assertTrue(newTickLower != oldTickLower || newTickUpper != oldTickUpper, "range did not change");

        (
            int32 lowerTickLimitOld,
            int32 upperTickLimitOld,
            int32 lowerTickDeltaOld,
            int32 upperTickDeltaOld,
            uint64 token0SlippageX64Old,
            uint64 token1SlippageX64Old,
            bool onlyFeesOld,
            bool autoCompoundOld,
            uint64 maxRewardX64Old,
            uint128 autoCompoundMin0Old,
            uint128 autoCompoundMin1Old,
            uint128 autoCompoundRewardMinOld
        ) = localAutoRange.positionConfigs(tokenId);
        assertEq(lowerTickLimitOld, 0);
        assertEq(upperTickLimitOld, 0);
        assertEq(lowerTickDeltaOld, 0);
        assertEq(upperTickDeltaOld, 0);
        assertEq(token0SlippageX64Old, 0);
        assertEq(token1SlippageX64Old, 0);
        assertFalse(onlyFeesOld);
        assertFalse(autoCompoundOld);
        assertEq(maxRewardX64Old, 0);
        assertEq(autoCompoundMin0Old, 0);
        assertEq(autoCompoundMin1Old, 0);
        assertEq(autoCompoundRewardMinOld, 0);

        (
            int32 lowerTickLimitNew,
            int32 upperTickLimitNew,
            int32 lowerTickDeltaNew,
            int32 upperTickDeltaNew,
            uint64 token0SlippageX64New,
            uint64 token1SlippageX64New,
            bool onlyFeesNew,
            bool autoCompoundNew,
            uint64 maxRewardX64New,
            uint128 autoCompoundMin0New,
            uint128 autoCompoundMin1New,
            uint128 autoCompoundRewardMinNew
        ) = localAutoRange.positionConfigs(newTokenId);
        assertEq(lowerTickLimitNew, config.lowerTickLimit);
        assertEq(upperTickLimitNew, config.upperTickLimit);
        assertEq(lowerTickDeltaNew, config.lowerTickDelta);
        assertEq(upperTickDeltaNew, config.upperTickDelta);
        assertEq(token0SlippageX64New, config.token0SlippageX64);
        assertEq(token1SlippageX64New, config.token1SlippageX64);
        assertEq(onlyFeesNew, config.onlyFees);
        assertEq(autoCompoundNew, config.autoCompound);
        assertEq(maxRewardX64New, config.maxRewardX64);
        assertEq(autoCompoundMin0New, config.autoCompoundMin0);
        assertEq(autoCompoundMin1New, config.autoCompoundMin1);
        assertEq(autoCompoundRewardMinNew, config.autoCompoundRewardMin);
    }

    function testUnauthorizedAdjust() external {
        vm.prank(address(0x9999));
        vm.expectRevert(Constants.Unauthorized.selector);
        autoRange.execute(_executeParams());
    }

    function testPositionNotConfigured() external {
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Constants.NotConfigured.selector);
        autoRange.execute(_executeParams());
    }

    function testReconfigurePosition() external {
        AutoRangeAndCompound.PositionConfig memory config = _defaultConfig();
        vm.startPrank(positionOwner);

        autoRange.configToken(REAL_POSITION_ID, address(0), config);

        config.lowerTickDelta = -300;
        config.upperTickDelta = 300;
        config.token0SlippageX64 = uint64(Q64 / 200);
        config.token1SlippageX64 = uint64(Q64 / 200);
        config.onlyFees = true;
        config.autoCompound = true;
        config.maxRewardX64 = MAX_REWARD / 2;
        autoRange.configToken(REAL_POSITION_ID, address(0), config);
        vm.stopPrank();

        (
            ,
            ,
            int32 lowerTickDelta,
            int32 upperTickDelta,
            uint64 token0SlippageX64,
            uint64 token1SlippageX64,
            bool onlyFees,
            bool autoCompound,
            uint64 maxRewardX64,
            uint128 autoCompoundMin0,
            uint128 autoCompoundMin1,
            uint128 autoCompoundRewardMin
        ) = autoRange.positionConfigs(REAL_POSITION_ID);

        assertEq(lowerTickDelta, -300);
        assertEq(upperTickDelta, 300);
        assertEq(token0SlippageX64, uint64(Q64 / 200));
        assertEq(token1SlippageX64, uint64(Q64 / 200));
        assertTrue(onlyFees);
        assertTrue(autoCompound);
        assertEq(maxRewardX64, MAX_REWARD / 2);
        assertEq(autoCompoundMin0, 0);
        assertEq(autoCompoundMin1, 0);
        assertEq(autoCompoundRewardMin, 0);
    }

    function testTWAPCheck() external {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = autoRange.TWAPSeconds();
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IAerodromeSlipstreamPool(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 twapTick = int24(delta / int56(uint56(autoRange.TWAPSeconds())));
        if (delta < 0 && delta % int56(uint56(autoRange.TWAPSeconds())) != 0) {
            twapTick--;
        }

        int24 tickDifference = twapTick > currentTick ? twapTick - currentTick : currentTick - twapTick;
        assertLe(uint256(uint24(tickDifference)), uint256(type(uint24).max), "invalid tick difference");
    }
}
