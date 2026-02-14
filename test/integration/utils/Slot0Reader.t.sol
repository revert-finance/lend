// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/utils/Slot0Reader.sol";
import "../aerodrome/mocks/MockPool.sol";

contract Slot0ReaderHarness {
    function read(address pool) external view returns (uint160 sqrtPriceX96, int24 tick) {
        return Slot0Reader.read(pool);
    }
}

contract MockSlipstreamSlot0Six {
    uint160 internal _sqrtPriceX96;
    int24 internal _tick;
    bool internal _unlocked;

    constructor(uint160 sqrtPriceX96_, int24 tick_, bool unlocked_) {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
        _unlocked = unlocked_;
    }

    // 6-return-value slot0() shape (no feeProtocol).
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        )
    {
        return (_sqrtPriceX96, _tick, 0, 0, 0, _unlocked);
    }
}

contract Slot0ReaderTest is Test {
    function testReadWorksFor6ReturnSlot0() public {
        Slot0ReaderHarness h = new Slot0ReaderHarness();
        MockSlipstreamSlot0Six p = new MockSlipstreamSlot0Six(uint160(123), int24(-42), true);

        (uint160 sqrtPriceX96, int24 tick) = h.read(address(p));
        assertEq(uint256(sqrtPriceX96), 123);
        assertEq(tick, -42);
    }

    function testReadWorksFor7ReturnSlot0() public {
        Slot0ReaderHarness h = new Slot0ReaderHarness();
        MockPool p = new MockPool(address(0x1), address(0x2), 1, 1);
        p.setSqrtPriceX96(uint160(456));
        p.setTick(int24(7));

        (uint160 sqrtPriceX96, int24 tick) = h.read(address(p));
        assertEq(uint256(sqrtPriceX96), 456);
        assertEq(tick, 7);
    }
}

