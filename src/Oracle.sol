// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./compound/PriceOracle.sol";
import "./compound/ComptrollerInterface.sol";
import "./compound/Lens/CompoundLens.sol";
import "./compound/CErc20.sol";

import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";

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

    uint256 consoletant Q96 = 2**96;

    error NoFeedConfigured();
    error InvalidPool();

    enum Mode {
        CHAINLINK_TWAP_VERIFY, // using chainlink for price and TWAP to verify
        TWAP_CHAINLINK_VERIFY, // using TWAP for price and chainlink to verify
        CHAINLINK, // using only chainlink directly
        TWAP // using TWAP directly
    }

    struct FeedConfig {
        AggregatorV3Interface feed; // chainlink feed
        uint32 maxFeedAge;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        IUniswapV3Pool pool; // reference pool
        bool isToken0;
        uint8 otherDecimals;
        uint32 twapSeconds;
        Mode mode;
        uint16 maxDifference; // max price difference x10000
    }

    // ctoken => config mapping
    mapping(address => FeedConfig) feedConfigs;
    
    constructor() {
    }

    // may be called again to update configuration
    function setTokenFeed(address cToken, AggregatorV3Interface feed, uint32 maxFeedAge, IUniswapV3Pool pool, uint32 twapSeconds, Mode mode, uint16 maxDifference) external onlyOwner {
        uint8 feedDecimals = feed.decimals();
        address underlying = CErc20Interface(address(cToken)).underlying();
        uint8 tokenDecimals = IERC20Metadata(underlying).decimals();
        address otherToken = pool.token0();
        bool isToken0 = otherToken == underlying;
        if (!isToken0) {
            if (pool.token1() != underlying) {
                revert InvalidPool();
            }
        } else {
            otherToken = pool.token1();
        }
        uint8 otherDecimals = IERC20Metadata(otherToken).decimals();
        feedConfigs[cToken] = FeedConfig(feed, maxFeedAge, feedDecimals, tokenDecimals, pool, isToken0, otherDecimals, twapSeconds, mode, maxDifference);
    }

    function setOracleMode(address cToken, Mode mode) external onlyOwner {
        feedConfigs[cToken].mode = mode;
    }

    function _getReferencePoolPrice(IUniswapV3Pool pool, uint32 twapSeconds, bool isToken0, uint8 tokenDecimals, uint8 otherDecimals, uint8 feedDecimals) internal view returns (uint256) {

        uint160 sqrtPriceX96;
        // if twap seconds set to 0 just use pool price
        if (twapSeconds == 0) {
            (sqrtPriceX96,,,,,,) = pool.slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = 0; // from (before)
            secondsAgos[1] = twapSeconds; // from (before)
            (int56[] memory tickCumulatives,) = pool.observe(secondsAgos); // pool observe may fail when there is not enough history available (only use pool with enough history!)
            int24 tick = int24((tickCumulatives[0] - tickCumulatives[1]) / int56(uint56(twapSeconds)));
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        }

        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (isToken0) {
            return FullMath.mulDiv(priceX96, 10 ** (feedDecimals + tokenDecimals - otherDecimals), Q96);
        } else {
            return FullMath.mulDiv(Q96, 10 ** (feedDecimals + tokenDecimals - otherDecimals), priceX96);
        }
    }

    function getUnderlyingPrice(CToken cToken) override external view returns (uint256 result) {
        FeedConfig storage feedConfig = feedConfigs[address(cToken)];

        uint256 price;
        uint256 verifyPrice;

        if (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY || feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY || feedConfig.mode == Mode.CHAINLINK) {
            if (address(feedConfig.feed) == address(0)) {
                revert NoFeedConfigured();
            }

            // if stale data - return 0 - handled as error in compound
            (, int256 answer, , uint256 updatedAt, ) = feedConfig.feed.latestRoundData();
            if (updatedAt + feedConfig.maxFeedAge < block.timestamp) {
                return 0;
            }
            // if invalid data - return 0 - handled as error in compound
            if (answer <= 0) {
                return 0;
            }

            if (feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY) {
                verifyPrice = uint256(answer);
            } else {
                price = uint256(answer);
            }
        }

        if (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY || feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY || feedConfig.mode == Mode.TWAP) {
             // get reference pool price
            uint256 poolTWAPPrice = _getReferencePoolPrice(feedConfig.pool, feedConfig.twapSeconds, feedConfig.isToken0, feedConfig.tokenDecimals, feedConfig.otherDecimals, feedConfig.feedDecimals);

            if (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY) {
                verifyPrice = poolTWAPPrice;
            } else {
                price = poolTWAPPrice;
            }
        }
        
        if (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY || feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY) {
            uint256 difference = price > verifyPrice ? FullMath.mulDiv(price - verifyPrice, 10000, price) : FullMath.mulDiv(verifyPrice - price, 10000, verifyPrice);

            // if too big difference - return 0 - handled as error in compound
            if (difference >= feedConfig.maxDifference) {
                return 0;
            }
        }


        // convert to compound expected format
        result = (10 ** (36 - feedConfig.feedDecimals - feedConfig.tokenDecimals)) * price;
    }
}
