// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracles/StockTwapFeed.sol";

contract StockRoundMock is AggregatorV3Interface {
    uint8 public override decimals = 8;
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 value, uint256 timestamp) external {
        answer = value;
        updatedAt = timestamp;
    }

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (17, answer, updatedAt - (updatedAt == 0 ? 0 : 1), updatedAt, 17);
    }
}

contract StockObservationMock {
    address public token0;
    address public token1;
    int56 public delta;
    int56 public past;
    bool public unavailable;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
    }

    function set(int56 value) external {
        delta = value;
    }

    function setPast(int56 value) external {
        past = value;
    }

    function setUnavailable() external {
        unavailable = true;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory c, uint160[] memory s) {
        require(!unavailable, "OLD");
        require(secondsAgos.length == 2 && secondsAgos[0] == 60 && secondsAgos[1] == 0, "window");
        c = new int56[](2);
        s = new uint160[](2);
        c[0] = past;
        unchecked {
            c[1] = past + delta;
        }
    }
}

contract StockTwapFeedTest is Test {
    StockRoundMock stockFeed;
    StockRoundMock usdcFeed;
    StockObservationMock pool;
    StockTwapFeed adapter;
    address constant STOCK = address(0x100);
    address constant USDC = address(0x200);

    function setUp() public {
        vm.warp(10 days);
        stockFeed = new StockRoundMock();
        usdcFeed = new StockRoundMock();
        stockFeed.set(100e8, block.timestamp - 30);
        usdcFeed.set(1e8, block.timestamp - 10);
        pool = new StockObservationMock(STOCK, USDC);
        adapter = makeAdapter(pool, STOCK, USDC, 60, 200);
    }

    function makeAdapter(StockObservationMock p, address stock, address usdc, uint32 window, uint16 tolerance)
        internal
        returns (StockTwapFeed)
    {
        return new StockTwapFeed(
            stockFeed, usdcFeed, IUniswapV3Pool(address(p)), stock, usdc, 86400, 86400, window, tolerance
        );
    }

    function testPreservesEntireOriginalRoundAndDecimals() public {
        (uint80 id, int256 answer, uint256 start, uint256 updated, uint80 answered) = adapter.latestRoundData();
        assertEq(id, 17);
        assertEq(answer, 100e8);
        assertEq(start, block.timestamp - 31);
        assertEq(updated, block.timestamp - 30);
        assertEq(answered, 17);
        assertEq(adapter.decimals(), 8);
    }

    function testUsdcDepegIsConvertedRatherThanAssumedOneDollar() public {
        // Pool tick 0 means 100 raw-decimal-adjusted USDC per stock, now worth $90.
        usdcFeed.set(0.9e8, block.timestamp);
        stockFeed.set(90e8, block.timestamp);
        adapter.latestRoundData();
        stockFeed.set(100e8, block.timestamp);
        vm.expectRevert(StockTwapFeed.PriceDifferenceExceeded.selector);
        adapter.latestRoundData();
    }

    function testBothTokenOrdersAtNonzeroTick() public {
        pool.set(6931 * 60); // raw token1/token0 ~2: stock/USD ~200
        stockFeed.set(200e8, block.timestamp);
        adapter.latestRoundData();
        StockObservationMock reversed = new StockObservationMock(STOCK, USDC);
        StockTwapFeed inverse = makeAdapter(reversed, USDC, STOCK, 60, 200);
        reversed.set(6931 * 60); // stock is now token1: stock/USD ~50
        stockFeed.set(50e8, block.timestamp);
        inverse.latestRoundData();
    }

    function testDivergenceInBothDirectionsReverts() public {
        pool.set(300 * 60);
        vm.expectRevert(StockTwapFeed.PriceDifferenceExceeded.selector);
        adapter.latestRoundData();
        pool.set(-300 * 60);
        vm.expectRevert(StockTwapFeed.PriceDifferenceExceeded.selector);
        adapter.latestRoundData();
    }

    function testWithinTwoPercentSucceeds() public {
        pool.set(190 * 60);
        adapter.latestRoundData();
        pool.set(-190 * 60);
        adapter.latestRoundData();
    }

    function testNegativeMeanTickRoundsDown() public {
        StockTwapFeed tight = makeAdapter(pool, STOCK, USDC, 60, 1);
        pool.set(-60);
        tight.latestRoundData();
        pool.set(-61); // Floor is -2, not -1; now exceeds one basis point.
        vm.expectRevert(StockTwapFeed.PriceDifferenceExceeded.selector);
        tight.latestRoundData();
    }

    function testTickCumulativeWrapPreservesMean() public {
        pool.setPast(type(int56).max - 10);
        pool.set(60);
        adapter.latestRoundData();
    }

    function testMissingHistoryFailsClosed() public {
        pool.setUnavailable();
        vm.expectRevert(bytes("OLD"));
        adapter.latestRoundData();
    }

    function testStaleStockAndUsdcIndependentlyRevert() public {
        stockFeed.set(100e8, block.timestamp - 86401);
        vm.expectRevert(StockTwapFeed.InvalidRound.selector);
        adapter.latestRoundData();
        stockFeed.set(100e8, block.timestamp);
        usdcFeed.set(1e8, block.timestamp - 86401);
        vm.expectRevert(StockTwapFeed.InvalidRound.selector);
        adapter.latestRoundData();
    }

    function testExactAgeBoundaryPassesAndNextSecondFails() public {
        stockFeed.set(100e8, block.timestamp - 86400);
        adapter.latestRoundData();
        vm.warp(block.timestamp + 1);
        vm.expectRevert(StockTwapFeed.InvalidRound.selector);
        adapter.latestRoundData();
    }

    function testInvalidRoundsOnEitherFeed() public {
        StockRoundMock[2] memory feeds = [stockFeed, usdcFeed];
        for (uint256 i; i < 2; ++i) {
            int256 valid = i == 0 ? int256(100e8) : int256(1e8);
            feeds[i].set(0, block.timestamp);
            vm.expectRevert(StockTwapFeed.InvalidRound.selector);
            adapter.latestRoundData();
            feeds[i].set(-1, block.timestamp);
            vm.expectRevert(StockTwapFeed.InvalidRound.selector);
            adapter.latestRoundData();
            feeds[i].set(valid, 0);
            vm.expectRevert(StockTwapFeed.InvalidRound.selector);
            adapter.latestRoundData();
            feeds[i].set(valid, block.timestamp + 1);
            vm.expectRevert(StockTwapFeed.InvalidRound.selector);
            adapter.latestRoundData();
            feeds[i].set(valid, block.timestamp);
        }
    }

    function testRejectInvalidConfiguration() public {
        vm.expectRevert(StockTwapFeed.InvalidConfig.selector);
        makeAdapter(pool, STOCK, USDC, 0, 200);
        vm.expectRevert(StockTwapFeed.InvalidConfig.selector);
        makeAdapter(pool, STOCK, USDC, 60, type(uint16).max);
        vm.expectRevert(StockTwapFeed.InvalidConfig.selector);
        makeAdapter(pool, address(0xBAD), USDC, 60, 200);
        stockFeed.setDecimals(18);
        vm.expectRevert(StockTwapFeed.InvalidConfig.selector);
        makeAdapter(pool, STOCK, USDC, 60, 200);
    }

    function testFuzzUsdcConversion(uint64 usdcPrice) public {
        // Keep pool ratio at tick zero, changing USD values of both assets proportionally.
        usdcPrice = uint64(bound(usdcPrice, 1e6, 2e8));
        uint64 price = usdcPrice * 100;
        stockFeed.set(int256(uint256(price)), block.timestamp);
        usdcFeed.set(int256(uint256(usdcPrice)), block.timestamp);
        (, int256 returned,,,) = adapter.latestRoundData();
        assertEq(returned, int256(uint256(price)));
    }
}
