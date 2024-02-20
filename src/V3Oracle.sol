// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";

import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";

import "v3-periphery/libraries/PoolAddress.sol";
import "v3-periphery/libraries/LiquidityAmounts.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../lib/AggregatorV3Interface.sol";

import "./interfaces/IV3Oracle.sol";
import "./interfaces/IErrors.sol";

/// @title V3Oracle to be used in V3Vault to calculate position values
/// @notice It uses both chainlink and uniswap v3 TWAP and provides emergency fallback mode
contract V3Oracle is IV3Oracle, Ownable, IErrors {
    uint16 public constant MIN_PRICE_DIFFERENCE = 200; //2%

    uint256 private constant Q96 = 2 ** 96;
    uint256 private constant Q128 = 2 ** 128;

    event TokenConfigUpdated(address indexed token, TokenConfig config);
    event OracleModeUpdated(address indexed token, Mode mode);
    event SetMaxPoolPriceDifference(uint16 maxPoolPriceDifference);
    event SetEmergencyAdmin(address emergencyAdmin);

    enum Mode {
        NOT_SET,
        CHAINLINK_TWAP_VERIFY, // using chainlink for price and TWAP to verify
        TWAP_CHAINLINK_VERIFY, // using TWAP for price and chainlink to verify
        CHAINLINK, // using only chainlink directly
        TWAP // using TWAP directly
    }

    struct TokenConfig {
        AggregatorV3Interface feed; // chainlink feed
        uint32 maxFeedAge;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        IUniswapV3Pool pool; // reference pool
        bool isToken0;
        uint32 twapSeconds;
        Mode mode;
        uint16 maxDifference; // max price difference x10000
    }

    // token => config mapping
    mapping(address => TokenConfig) public feedConfigs;

    address public immutable factory;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    // common token which is used in TWAP pools
    address public immutable referenceToken;
    uint8 public immutable referenceTokenDecimals;

    uint16 public maxPoolPriceDifference = MIN_PRICE_DIFFERENCE; // max price difference between oracle derived price and pool price x10000

    // common token which is used in chainlink feeds as "pair" (address(0) if USD or another non-token reference)
    address public immutable chainlinkReferenceToken;

    // address which can call special emergency actions without timelock
    address public emergencyAdmin;

    // constructor: sets owner of contract
    constructor(
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _referenceToken,
        address _chainlinkReferenceToken
    ) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _nonfungiblePositionManager.factory();
        referenceToken = _referenceToken;
        referenceTokenDecimals = IERC20Metadata(_referenceToken).decimals();
        chainlinkReferenceToken = _chainlinkReferenceToken;
    }

    // gets value of a uniswap v3 lp position in specified token
    // uses configured oracles and verfies price on second oracle - if fails - reverts
    // returns complete value and fee-only value
    function getValue(uint256 tokenId, address token)
        external
        view
        override
        returns (uint256 value, uint256 feeValue, uint256 price0X96, uint256 price1X96)
    {
        (address token0, address token1, uint24 fee,, uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1) =
            getPositionBreakdown(tokenId);

        uint256 cachedChainlinkReferencePriceX96;

        (price0X96, cachedChainlinkReferencePriceX96) =
            _getReferenceTokenPriceX96(token0, cachedChainlinkReferencePriceX96);
        (price1X96, cachedChainlinkReferencePriceX96) =
            _getReferenceTokenPriceX96(token1, cachedChainlinkReferencePriceX96);

        uint256 priceTokenX96;
        if (token0 == token) {
            priceTokenX96 = price0X96;
        } else if (token1 == token) {
            priceTokenX96 = price1X96;
        } else {
            (priceTokenX96,) = _getReferenceTokenPriceX96(token, cachedChainlinkReferencePriceX96);
        }

        value = (price0X96 * (amount0 + fees0) / Q96 + price1X96 * (amount1 + fees1) / Q96) * Q96 / priceTokenX96;
        feeValue = (price0X96 * fees0 / Q96 + price1X96 * fees1 / Q96) * Q96 / priceTokenX96;
        price0X96 = price0X96 * Q96 / priceTokenX96;
        price1X96 = price1X96 * Q96 / priceTokenX96;

        // checks derived pool price for price manipulation attacks
        // this prevents manipulations of pool to get distorted proportions of collateral tokens - for borrowing
        // when a pool is in this state, liquidations will be disabled - but arbitrageurs (or liquidator himself)
        // will move price back to reasonable range and enable liquidation
        uint256 derivedPoolPriceX96 = price0X96 * Q96 / price1X96;
        _checkPoolPrice(token0, token1, fee, derivedPoolPriceX96);
    }

    function _checkPoolPrice(address token0, address token1, uint24 fee, uint256 derivedPoolPriceX96) internal view {
        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        uint256 priceX96 = _getReferencePoolPriceX96(pool, 0);
        _requireMaxDifference(priceX96, derivedPoolPriceX96, maxPoolPriceDifference);
    }

    function _requireMaxDifference(uint256 priceX96, uint256 verifyPriceX96, uint256 maxDifferenceX10000)
        internal
        pure
    {
        uint256 differenceX10000 = priceX96 > verifyPriceX96
            ? (priceX96 - verifyPriceX96) * 10000 / priceX96
            : (verifyPriceX96 - priceX96) * 10000 / verifyPriceX96;
        // if too big difference - revert
        if (differenceX10000 >= maxDifferenceX10000) {
            revert PriceDifferenceExceeded();
        }
    }

    // gets breakdown of a uniswap v3 position (liquidity, current liquidity amounts, uncollected fees)
    function getPositionBreakdown(uint256 tokenId)
        public
        view
        override
        returns (
            address token0,
            address token1,
            uint24 fee,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            uint128 fees0,
            uint128 fees1
        )
    {
        PositionState memory state = _initializeState(tokenId);
        (token0, token1, fee) = (state.token0, state.token1, state.fee);
        (amount0, amount1, fees0, fees1) = _getAmounts(state);
        liquidity = state.liquidity;
    }

    // Sets the max pool difference parameter
    function setMaxPoolPriceDifference(uint16 _maxPoolPriceDifference) external onlyOwner {
        if (_maxPoolPriceDifference < MIN_PRICE_DIFFERENCE) {
            revert InvalidConfig();
        }
        maxPoolPriceDifference = _maxPoolPriceDifference;
        emit SetMaxPoolPriceDifference(_maxPoolPriceDifference);
    }

    // Sets or updates the feed configuration for a token
    // Can only be called by the owner of the contract
    function setTokenConfig(
        address token,
        AggregatorV3Interface feed,
        uint32 maxFeedAge,
        IUniswapV3Pool pool,
        uint32 twapSeconds,
        Mode mode,
        uint16 maxDifference
    ) external onlyOwner {
        // can not be unset
        if (mode == Mode.NOT_SET) {
            revert InvalidConfig();
        }

        uint8 feedDecimals = feed.decimals();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        TokenConfig memory config;

        if (token != referenceToken) {
            if (maxDifference < MIN_PRICE_DIFFERENCE) {
                revert InvalidConfig();
            }

            address token0 = pool.token0();
            address token1 = pool.token1();
            if (!(token0 == token && token1 == referenceToken || token0 == referenceToken && token1 == token)) {
                revert InvalidPool();
            }
            bool isToken0 = token0 == token;
            config = TokenConfig(
                feed, maxFeedAge, feedDecimals, tokenDecimals, pool, isToken0, twapSeconds, mode, maxDifference
            );
        } else {
            config = TokenConfig(
                feed, maxFeedAge, feedDecimals, tokenDecimals, IUniswapV3Pool(address(0)), false, 0, Mode.CHAINLINK, 0
            );
        }

        feedConfigs[token] = config;

        emit TokenConfigUpdated(token, config);
        emit OracleModeUpdated(token, mode);
    }

    // Updates the oracle mode for a given token  - this method can be called by owner OR emergencyAdmin
    function setOracleMode(address token, Mode mode) external {
        if (msg.sender != emergencyAdmin && msg.sender != owner()) {
            revert Unauthorized();
        }

        // can not be unset
        if (mode == Mode.NOT_SET) {
            revert InvalidConfig();
        }

        feedConfigs[token].mode = mode;
        emit OracleModeUpdated(token, mode);
    }

    // function to set emergency admin address
    function setEmergencyAdmin(address admin) external onlyOwner {
        emergencyAdmin = admin;
        emit SetEmergencyAdmin(admin);
    }

    // Returns the price for a token using the selected oracle mode given as reference token value
    // The price is calculated using Chainlink, Uniswap v3 TWAP, or both based on the mode
    function _getReferenceTokenPriceX96(address token, uint256 cachedChainlinkReferencePriceX96)
        internal
        view
        returns (uint256 priceX96, uint256 chainlinkReferencePriceX96)
    {
        if (token == referenceToken) {
            return (Q96, chainlinkReferencePriceX96);
        }

        TokenConfig memory feedConfig = feedConfigs[token];

        if (feedConfig.mode == Mode.NOT_SET) {
            revert NotConfigured();
        }

        uint256 verifyPriceX96;

        bool usesChainlink = (
            feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY || feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY
                || feedConfig.mode == Mode.CHAINLINK
        );
        bool usesTWAP = (
            feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY || feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY
                || feedConfig.mode == Mode.TWAP
        );

        if (usesChainlink) {
            uint256 chainlinkPriceX96 = _getChainlinkPriceX96(token);
            chainlinkReferencePriceX96 = cachedChainlinkReferencePriceX96 == 0
                ? _getChainlinkPriceX96(referenceToken)
                : cachedChainlinkReferencePriceX96;

            chainlinkPriceX96 = (10 ** referenceTokenDecimals) * chainlinkPriceX96 * Q96 / chainlinkReferencePriceX96
                / (10 ** feedConfig.tokenDecimals);

            if (feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY) {
                verifyPriceX96 = chainlinkPriceX96;
            } else {
                priceX96 = chainlinkPriceX96;
            }
        }

        if (usesTWAP) {
            uint256 twapPriceX96 = _getTWAPPriceX96(feedConfig);
            if (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY) {
                verifyPriceX96 = twapPriceX96;
            } else {
                priceX96 = twapPriceX96;
            }
        }

        if (feedConfig.mode == Mode.CHAINLINK_TWAP_VERIFY || feedConfig.mode == Mode.TWAP_CHAINLINK_VERIFY) {
            _requireMaxDifference(priceX96, verifyPriceX96, feedConfig.maxDifference);
        }
    }

    // calculates chainlink price given feedConfig
    function _getChainlinkPriceX96(address token) internal view returns (uint256) {
        if (token == chainlinkReferenceToken) {
            return Q96;
        }

        TokenConfig memory feedConfig = feedConfigs[token];

        // if stale data - revert
        (, int256 answer,, uint256 updatedAt,) = feedConfig.feed.latestRoundData();
        if (updatedAt + feedConfig.maxFeedAge < block.timestamp || answer < 0) {
            revert ChainlinkPriceError();
        }

        return uint256(answer) * Q96 / (10 ** feedConfig.feedDecimals);
    }

    // calculates TWAP price given feedConfig
    function _getTWAPPriceX96(TokenConfig memory feedConfig) internal view returns (uint256 poolTWAPPriceX96) {
        // get reference pool price
        uint256 priceX96 = _getReferencePoolPriceX96(feedConfig.pool, feedConfig.twapSeconds);

        if (feedConfig.isToken0) {
            poolTWAPPriceX96 = priceX96;
        } else {
            poolTWAPPriceX96 = Q96 * Q96 / priceX96;
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

    struct PositionState {
        uint256 tokenId;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        IUniswapV3Pool pool;
        uint160 sqrtPriceX96;
        int24 tick;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
    }

    function _initializeState(uint256 tokenId) internal view returns (PositionState memory state) {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = nonfungiblePositionManager.positions(tokenId);
        state.tokenId = tokenId;
        state.token0 = token0;
        state.token1 = token1;
        state.fee = fee;
        state.tickLower = tickLower;
        state.tickUpper = tickUpper;
        state.liquidity = liquidity;
        state.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        state.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        state.tokensOwed0 = tokensOwed0;
        state.tokensOwed1 = tokensOwed1;
        state.pool = _getPool(token0, token1, fee);
        (state.sqrtPriceX96, state.tick,,,,,) = state.pool.slot0();
    }

    // calculate position amounts given current price/tick
    function _getAmounts(PositionState memory state)
        internal
        view
        returns (uint256 amount0, uint256 amount1, uint128 fees0, uint128 fees1)
    {
        if (state.liquidity > 0) {
            state.sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(state.tickLower);
            state.sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(state.tickUpper);
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                state.sqrtPriceX96, state.sqrtPriceX96Lower, state.sqrtPriceX96Upper, state.liquidity
            );
        }

        (fees0, fees1) = _getUncollectedFees(state, state.tick);
        fees0 += state.tokensOwed0;
        fees1 += state.tokensOwed1;
    }

    // calculate uncollected fees
    function _getUncollectedFees(PositionState memory position, int24 tick)
        internal
        view
        returns (uint128 fees0, uint128 fees1)
    {
        (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = _getFeeGrowthInside(
            position.pool,
            position.tickLower,
            position.tickUpper,
            tick,
            position.pool.feeGrowthGlobal0X128(),
            position.pool.feeGrowthGlobal1X128()
        );

        // allow overflow - this is as designed by uniswap - see PositionValue library (for solidity < 0.8)
        uint256 feeGrowth0;
        uint256 feeGrowth1;
        unchecked {
            feeGrowth0 = feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128;
            feeGrowth1 = feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128;
        }

        fees0 = uint128(FullMath.mulDiv(feeGrowth0, position.liquidity, Q128));
        fees1 = uint128(FullMath.mulDiv(feeGrowth1, position.liquidity, Q128));
    }

    // calculate fee growth for uncollected fees calculation
    function _getFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);

        // allow overflow - this is as designed by uniswap - see PositionValue library (for solidity < 0.8)
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent < tickUpper) {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            }
        }
    }

    // helper method to get pool for token
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }
}
