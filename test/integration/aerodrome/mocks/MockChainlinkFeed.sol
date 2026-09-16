// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../../../lib/AggregatorV3Interface.sol";

/// @notice Chainlink aggregator mock with a settable answer, timestamp and failure switch.
///         Unlike MockChainlinkAggregator in AerodromeTestBase, updatedAt does not track
///         block.timestamp, so staleness can be tested.
contract MockChainlinkFeed is AggregatorV3Interface {
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public updatedAt;
    uint8 private immutable _decimals;
    bool private _revert;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        _decimals = decimals_;
        updatedAt = block.timestamp;
    }

    /// @dev new round: fresh timestamp
    function setAnswer(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function setRevert(bool revert_) external {
        _revert = revert_;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!_revert, "feed: down");
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }
}
