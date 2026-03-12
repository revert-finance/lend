// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../src/automators/Automator.sol";

contract MockNpmForAutomator {
    address public immutable factory;
    address public immutable WETH9;

    constructor(address _factory, address _weth9) {
        factory = _factory;
        WETH9 = _weth9;
    }
}

contract MockPoolSlot0 {
    uint160 private _sqrtPriceX96;
    int24 private _tick;

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_) external {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (_sqrtPriceX96, _tick, 0, 0, 0, 0, true);
    }
}

contract AutomatorSlot0Harness is Automator {
    constructor(INonfungiblePositionManager npm)
        Automator(npm, address(0x1111), address(0x2222), 60, 200, address(0), address(0))
    {}

    function getPoolSlot0(IUniswapV3Pool pool) external view returns (uint160 sqrtPriceX96, int24 tick) {
        return _getPoolSlot0(pool);
    }
}

contract AutomatorSlot0UnitTest is Test {
    AutomatorSlot0Harness internal harness;
    MockPoolSlot0 internal pool;

    function setUp() external {
        MockNpmForAutomator npm = new MockNpmForAutomator(address(0xBEEF), address(0xCAFE));
        harness = new AutomatorSlot0Harness(INonfungiblePositionManager(address(npm)));
        pool = new MockPoolSlot0();
    }

    function testGetPoolSlot0HandlesNegativeTick() external {
        int24 expectedTick = -276_326;
        uint160 expectedSqrtPriceX96 = uint160(1 << 96);
        pool.setSlot0(expectedSqrtPriceX96, expectedTick);

        (uint160 sqrtPriceX96, int24 tick) = harness.getPoolSlot0(IUniswapV3Pool(address(pool)));

        assertEq(uint256(sqrtPriceX96), uint256(expectedSqrtPriceX96));
        assertEq(int256(tick), int256(expectedTick));
    }
}
