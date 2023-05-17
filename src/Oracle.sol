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

/// @title Oracle to be used in Revert Compound integration
/// @notice It uses both chainlink and uniswap v3 TWAP and provides emergency fallback mode
contract Oracle is PriceOracle, Ownable {

    uint256 constant Q96 = 2**96;

    error NoFeedConfigured();
    error InvalidPool();

    event FeedConfigUpdated(
        address indexed cToken,
        FeedConfig config
    );

    event OracleModeUpdated(
        address indexed cToken,
        Mode mode
    );

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
    
    // constructor: sets owner of contract
    constructor() {
    }

    // Sets or updates the feed configuration for a cToken
    // Can only be called by the owner of the contract
    function setTokenFeed(CErc20Interface cToken, AggregatorV3Interface feed, uint32 maxFeedAge, IUniswapV3Pool pool, uint32 twapSeconds, Mode mode, uint16 maxDifference) external onlyOwner {
        uint8 feedDecimals = feed.decimals();
        address underlying = cToken.underlying();
        uint8 tokenDecimals = IERC20Metadata(underlying).decimals();
        address otherToken = pool.token0();
        bool isToken0 = otherToken == underlying;
        if (!isToken0 && pool.token1() != underlying) {
            revert InvalidPool();
        }
        if (isToken0) {
            otherToken = pool.token1();
        }
        uint8 otherDecimals = IERC20Metadata(otherToken).decimals();
        address cTokenAddress = address(cToken);
        FeedConfig memory config = FeedConfig(feed, maxFeedAge, feedDecimals, tokenDecimals, pool, isToken0, otherDecimals, twapSeconds, mode, maxDifference);
        feedConfigs[cTokenAddress] = config;

        emit FeedConfigUpdated(cTokenAddress, config);
    }

    // Updates the oracle mode for a cToken
    // Can only be called by the owner of the contract
    function setOracleMode(address cToken, Mode mode) external onlyOwner {
        feedConfigs[cToken].mode = mode;
        
        emit OracleModeUpdated(cToken, mode);
    }

    // Returns the underlying price for a cToken using the selected oracle mode
    // The price is calculated using Chainlink, Uniswap v3 TWAP, or both based on the mode
    function getUnderlyingPrice(CToken cToken) override external view returns (uint256 result) {
        FeedConfig storage feedConfig = feedConfigs[address(cToken)];

        uint256 price;
        uint256 verifyPrice;

        bool usesChainlink = (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY || feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY || feedConfig.mode == Mode.CHAINLINK);
        bool usesTWAP = (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY || feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY || feedConfig.mode == Mode.TWAP);

        if (usesChainlink) {
            uint256 chainlinkPrice = _getChainlinkPrice(feedConfig);
            if (chainlinkPrice == 0) {
                return 0;
            }
            if (feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY) {
                verifyPrice = chainlinkPrice;
            } else {
                price = chainlinkPrice;
            }
        }

        if (usesTWAP) {
            uint256 twapPrice = _getTWAPPrice(feedConfig);
            if (twapPrice == 0) {
                return 0;
            }
            if (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY) {
                verifyPrice = twapPrice;
            } else {
                price = twapPrice;
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

    // calculates chainlink price given feedConfig
    function _getChainlinkPrice(FeedConfig storage feedConfig) internal view returns (uint256) {
        if (address(feedConfig.feed) == address(0)) {
            revert NoFeedConfigured();
        }

        // if stale data - return 0 - handled as error in compound
        (, int256 answer, , uint256 updatedAt, ) = feedConfig.feed.latestRoundData();
        if (updatedAt + feedConfig.maxFeedAge < block.timestamp || answer <= 0) {
            return 0;
        }

        return uint256(answer);
    }

    // calculates TWAP price given feedConfig
    function _getTWAPPrice(FeedConfig storage feedConfig) internal view returns (uint256 poolTWAPPrice) {
        // get reference pool price
        uint256 priceX96 = _getReferencePoolPriceX96(feedConfig.pool, feedConfig.twapSeconds);

        // convert to chainlink price format
        if (feedConfig.isToken0) {
            if (feedConfig.feedDecimals + feedConfig.tokenDecimals >= feedConfig.otherDecimals) {
                poolTWAPPrice = FullMath.mulDiv(priceX96, 10 ** (feedConfig.feedDecimals + feedConfig.tokenDecimals - feedConfig.otherDecimals), Q96);
            } else {
                poolTWAPPrice = priceX96 / (Q96 * 10 ** (feedConfig.otherDecimals - feedConfig.feedDecimals - feedConfig.tokenDecimals));
            }
        } else {
            if (feedConfig.feedDecimals + feedConfig.tokenDecimals >= feedConfig.otherDecimals) {
                poolTWAPPrice = FullMath.mulDiv(Q96, 10 ** (feedConfig.feedDecimals + feedConfig.tokenDecimals - feedConfig.otherDecimals), priceX96);
            } else {
                poolTWAPPrice = Q96 / (priceX96 * 10 ** (feedConfig.otherDecimals - feedConfig.feedDecimals - feedConfig.tokenDecimals));
            }
        }
    }

    // Calculates the reference pool price with scaling factor of 2^96
    // It uses either the latest slot price or TWAP based on twapSeconds
    function _getReferencePoolPriceX96(IUniswapV3Pool pool, uint32 twapSeconds) internal view returns (uint256) {

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

        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
    }
}
