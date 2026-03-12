// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../src/V3Oracle.sol";

contract MockTokenDecimals {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract MockNpmForOracle {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }
}

contract MockPoolSlot0ForOracle {
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

contract V3OracleSlot0Harness is V3Oracle {
    constructor(INonfungiblePositionManager npm, address referenceToken) V3Oracle(npm, referenceToken, address(0)) {}

    function getPoolSlot0(IUniswapV3Pool pool) external view returns (uint160 sqrtPriceX96, int24 tick) {
        return _getPoolSlot0(pool);
    }
}

contract V3OracleSlot0UnitTest is Test {
    V3OracleSlot0Harness internal harness;
    MockPoolSlot0ForOracle internal pool;

    function setUp() external {
        MockTokenDecimals referenceToken = new MockTokenDecimals(6);
        MockNpmForOracle npm = new MockNpmForOracle(address(0xBEEF));
        harness = new V3OracleSlot0Harness(
            INonfungiblePositionManager(address(npm)),
            address(referenceToken)
        );
        pool = new MockPoolSlot0ForOracle();
    }

    function testGetPoolSlot0HandlesNegativeTick() external {
        int24 expectedTick = -276_326;
        uint160 expectedSqrtPriceX96 = uint160(1 << 96);
        pool.setSlot0(expectedSqrtPriceX96, expectedTick);

        (uint160 sqrtPriceX96, int24 tick) = harness.getPoolSlot0(IUniswapV3Pool(address(pool)));

        assertEq(uint256(sqrtPriceX96), uint256(expectedSqrtPriceX96));
        assertEq(int256(tick), int256(expectedTick));
    }

    function testGetPoolSlot0HandlesMinTick() external {
        int24 expectedTick = -887_272;
        uint160 expectedSqrtPriceX96 = uint160(1 << 90);
        pool.setSlot0(expectedSqrtPriceX96, expectedTick);

        (uint160 sqrtPriceX96, int24 tick) = harness.getPoolSlot0(IUniswapV3Pool(address(pool)));

        assertEq(uint256(sqrtPriceX96), uint256(expectedSqrtPriceX96));
        assertEq(int256(tick), int256(expectedTick));
    }
}
