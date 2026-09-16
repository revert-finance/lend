// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../src/utils/ChainlinkMultiplierFeed.sol";
import "../../lib/AggregatorV3Interface.sol";

contract MockShareFeed is AggregatorV3Interface {
    uint80 public roundId = 346;
    int256 public answer;
    uint256 public startedAt = 1_000_000;
    uint256 public updatedAt = 1_000_100;
    uint80 public answeredInRound = 346;
    uint8 private immutable _decimals;
    bool private _revert;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        _decimals = decimals_;
    }

    function set(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
    }

    function setRevert(bool revert_) external {
        _revert = revert_;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!_revert, "feed: down");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }
}

contract MockB20Multiplier is IB20Multiplier {
    uint256 private _multiplier;
    bool private _revert;

    constructor(uint256 multiplier_) {
        _multiplier = multiplier_;
    }

    function setMultiplier(uint256 multiplier_) external {
        _multiplier = multiplier_;
    }

    function setRevert(bool revert_) external {
        _revert = revert_;
    }

    function multiplier() external view override returns (uint256) {
        require(!_revert, "B20: not implemented");
        return _multiplier;
    }
}

contract ChainlinkMultiplierFeedTest is Test {
    // Coinbase NVDA close on Fri 2026-09-11, 8 decimals
    int256 constant NVDA_SHARE_PRICE = 218_28000000;
    // GOOGLc multiplier observed on-chain after its first cash dividend
    uint256 constant GOOGL_DIVIDEND_MULTIPLIER = 1.000377118676784179e18;

    MockShareFeed feed;
    MockB20Multiplier token;
    ChainlinkMultiplierFeed adapter;

    function setUp() external {
        feed = new MockShareFeed(NVDA_SHARE_PRICE, 8);
        token = new MockB20Multiplier(1e18);
        adapter = new ChainlinkMultiplierFeed(feed, token);
    }

    function _answer() internal view returns (int256 answer) {
        (, answer,,,) = adapter.latestRoundData();
    }

    function testLinkage() external {
        assertEq(address(adapter.feed()), address(feed));
        assertEq(address(adapter.token()), address(token));
    }

    function testDecimalsPassthrough() external {
        assertEq(adapter.decimals(), 8);
    }

    function testDecimalsReadOnce() external {
        MockShareFeed feed18 = new MockShareFeed(1e18, 18);
        ChainlinkMultiplierFeed adapter18 = new ChainlinkMultiplierFeed(feed18, token);
        assertEq(adapter18.decimals(), 18);
    }

    function testIdentityMultiplier() external {
        assertEq(_answer(), NVDA_SHARE_PRICE);
    }

    function testRoundMetadataPassthrough() external {
        feed.set(347, NVDA_SHARE_PRICE, 5_000, 6_000, 347);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.latestRoundData();
        assertEq(roundId, 347);
        assertEq(answer, NVDA_SHARE_PRICE);
        assertEq(startedAt, 5_000);
        assertEq(updatedAt, 6_000);
        assertEq(answeredInRound, 347);
    }

    // dividend: multiplier moves ~0.04%, price tracks, error far below any divergence tolerance
    function testDividendMultiplierTracks() external {
        token.setMultiplier(GOOGL_DIVIDEND_MULTIPLIER);
        int256 expected = int256(FullMath.mulDiv(uint256(NVDA_SHARE_PRICE), GOOGL_DIVIDEND_MULTIPLIER, 1e18));
        assertEq(_answer(), expected);
        assertEq(_answer(), 218_36231746); // 218.28 * 1.000377118676784179 = 218.362317464..., floored
    }

    // 2:1 split: each token now represents two shares, so per-token price doubles the per-share feed
    function testForwardSplitDoubles() external {
        token.setMultiplier(2e18);
        assertEq(_answer(), NVDA_SHARE_PRICE * 2);
    }

    // 1:2 reverse split
    function testReverseSplitHalves() external {
        token.setMultiplier(0.5e18);
        assertEq(_answer(), NVDA_SHARE_PRICE / 2);
    }

    // issuer emergency cut is reflected immediately in the derived price
    function testEmergencyCut() external {
        token.setMultiplier(0.25e18);
        assertEq(_answer(), NVDA_SHARE_PRICE / 4);
    }

    function testFloorsRounding() external {
        feed.setAnswer(3);
        token.setMultiplier(0.5e18);
        assertEq(_answer(), 1); // 1.5 floors to 1
    }

    // invalid inputs yield 0 so V3Oracle's answer <= 0 check rejects the round
    function testZeroMultiplierYieldsZero() external {
        token.setMultiplier(0);
        assertEq(_answer(), 0);
    }

    function testZeroAnswerYieldsZero() external {
        feed.setAnswer(0);
        assertEq(_answer(), 0);
    }

    function testNegativeAnswerYieldsZero() external {
        feed.setAnswer(-1);
        assertEq(_answer(), 0);
    }

    function testNegativeAnswerWithLargeMultiplierYieldsZero() external {
        feed.setAnswer(-NVDA_SHARE_PRICE);
        token.setMultiplier(5e18);
        assertEq(_answer(), 0);
    }

    // a reverting multiplier() (native client regression, not-implemented selector) reverts the adapter
    function testRevertingMultiplierReverts() external {
        token.setRevert(true);
        vm.expectRevert("B20: not implemented");
        adapter.latestRoundData();
    }

    function testRevertingFeedReverts() external {
        feed.setRevert(true);
        vm.expectRevert("feed: down");
        adapter.latestRoundData();
    }

    function testNoOwnerOrSetters() external {
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(adapter).call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        assertFalse(ok);
    }

    function testFuzzMatchesMulDiv(uint256 shareAnswer, uint256 multiplier) external {
        shareAnswer = bound(shareAnswer, 1, 1e24); // up to $1e16/share at 8 decimals
        multiplier = bound(multiplier, 1, 1e24); // up to 1e6 shares per token
        feed.setAnswer(int256(shareAnswer));
        token.setMultiplier(multiplier);
        assertEq(_answer(), int256(FullMath.mulDiv(shareAnswer, multiplier, 1e18)));
    }

    function testFuzzNonPositiveAnswerYieldsZero(uint256 magnitude, uint256 multiplier) external {
        magnitude = bound(magnitude, 0, uint256(type(int256).max));
        feed.setAnswer(-int256(magnitude));
        token.setMultiplier(multiplier);
        assertEq(_answer(), 0);
    }
}
