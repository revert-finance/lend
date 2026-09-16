// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../../lib/AggregatorV3Interface.sol";
import "v3-core/libraries/FullMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../interfaces/IB20Multiplier.sol";

/// @title Helper contract which scales a per-share chainlink feed by a B20 token's corporate-action multiplier
/// @notice Chainlink "Coinbase TICKER" feeds quote one share. A B20 token represents multiplier()/1e18 shares
///         after dividends, splits or issuer adjustments, so the per-token price is answer * multiplier / 1e18.
///         Follows ChainlinkFeedCombinator: immutable, no owner, and invalid inputs yield answer 0 so that
///         V3Oracle rejects the round (fail-closed). A reverting multiplier() call reverts here as well.
contract ChainlinkMultiplierFeed is AggregatorV3Interface {
    uint256 constant MULTIPLIER_ONE = 1e18;

    AggregatorV3Interface public immutable feed;
    IB20Multiplier public immutable token;
    uint8 immutable feedDecimals;

    constructor(AggregatorV3Interface _feed, IB20Multiplier _token) {
        feed = _feed;
        token = _token;
        feedDecimals = _feed.decimals();
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        int256 shareAnswer;
        (roundId, shareAnswer, startedAt, updatedAt, answeredInRound) = feed.latestRoundData();

        uint256 multiplier = token.multiplier();

        // only do calculation with valid values - otherwise returns 0
        // rounding down loses at most one unit of feed precision, far below any divergence tolerance
        if (shareAnswer > 0 && multiplier > 0) {
            answer = SafeCast.toInt256(FullMath.mulDiv(SafeCast.toUint256(shareAnswer), multiplier, MULTIPLIER_ONE));
        }
    }

    function decimals() external view override returns (uint8) {
        return feedDecimals;
    }
}
