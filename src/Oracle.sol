// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./compound/PriceOracle.sol";
import "./compound/ComptrollerInterface.sol";
import "./compound/Lens/CompoundLens.sol";
import "./compound/CErc20.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );

    function decimals() external view returns (uint8);
}
contract Oracle is PriceOracle, Ownable {

    error NoFeedConfigured();

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxFeedAge;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    // ctoken => config mapping
    mapping(address => FeedConfig) feedConfigs;
    
    constructor() {
    }

    function setTokenFeed(address cToken, AggregatorV3Interface feed, uint32 maxFeedAge) external onlyOwner {
        uint8 feedDecimals = feed.decimals();
        address underlying = CErc20Interface(address(cToken)).underlying();
        uint8 tokenDecimals = IERC20Metadata(underlying).decimals();
        feedConfigs[cToken] = FeedConfig(feed, maxFeedAge, feedDecimals, tokenDecimals);
    }

    function getUnderlyingPrice(CToken cToken) override external view returns (uint256) {
        FeedConfig storage feedConfig = feedConfigs[address(cToken)];
        if (address(feedConfig.feed) == address(0)) {
            revert NoFeedConfigured();
        }

        // if stale data - return 0 - handled as error in compound 
        (, int256 answer, , uint256 updatedAt, ) = feedConfig.feed.latestRoundData();
        if (updatedAt + feedConfig.maxFeedAge < block.timestamp) {
            return 0;
        }
        // if invalid data - return 0 - handled as error in compound 
        if (answer < 0) {
            return 0;
        }

        // convert to compound expected format
        return (10 ** (36 - feedConfig.feedDecimals - feedConfig.tokenDecimals)) * uint256(answer);
    }
}
