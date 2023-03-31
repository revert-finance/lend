// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Runner.sol";

/// @title RangeAdjustor
/// @notice Allows operator of RangeAdjustor contract (Revert controlled bot) to change range for configured positions
/// Positions need to be approved for all NFTs for the contract and configured with setConfig method
contract RangeAdjustor is Runner {

    error Unauthorized();
    error WrongContract();
    error AdjustStateError();
    error NotConfigured();
    error NotReady();
    error SameRange();

    event PositionConfigured(
        uint256 indexed tokenId,
        int32 lowerTickLimit,
        int32 upperTickLimit,
        int32 lowerTickDelta,
        int32 upperTickDelta,
        uint64 maxSlippageX64,
        uint64 maxGasFeeRewardX64
    );
    event RangeChanged(uint256 indexed oldTokenId, uint256 indexed newTokenId);


    // defines when and how a position can be changed by operator
    // when a position is adjusted config for the position is cleared and copied to the newly created position
    struct PositionConfig {
        // needs more than int24 because it can be [-type(uint24).max,type(uint24).max]
        int32 lowerTickLimit; // if negative also in-range positions may be adjusted
        int32 upperTickLimit; // if negative also in-range positions may be adjusted
        int32 lowerTickDelta; // this amount is added to current tick (floored to tickspacing) to define lowerTick of new position
        int32 upperTickDelta; // this amount is added to current tick (floored to tickspacing) to define upperTick of new position
        uint64 maxSlippageX64; // max allowed swap slippage including fees, price impact and slippage - from current pool price (to be sure revert bot can not do silly things)
        uint64 maxGasFeeRewardX64; // max allowed token percentage to be available for covering gas cost of operator (operator chooses which one of the two tokens to receive after swap)
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public configs;

    constructor(V3Utils _v3Utils, address _operator, uint32 _TWAPSeconds, uint16 _maxTWAPTickDifference) Runner(_v3Utils, _operator, _TWAPSeconds, _maxTWAPTickDifference) {
    }

    /**
     * @notice Sets config for a given NFT - must be owner
     * To disable a position set everything to default value
     */
    function setConfig(
        uint256 tokenId,
        PositionConfig calldata config
    ) external {
        // lower tick must be always below or equal to upper tick - if they are equal - range adjustment is deactivated
        if (config.lowerTickDelta > config.upperTickDelta) {
            revert InvalidConfig();
        }

        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }
        configs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.lowerTickLimit,
            config.upperTickLimit,
            config.lowerTickDelta,
            config.upperTickDelta,
            config.maxSlippageX64,
            config.maxGasFeeRewardX64
        );
    }

    struct AdjustParams {
        uint256 tokenId;
        bool swap0To1;
        uint256 amountIn; // if this is set to 0 no swap happens
        bytes swapData;
        uint256 deadline; // for uniswap operations - operator promises fair value
        bool takeFeeFrom0;
        uint256 feeAmount;
    }

    struct AdjustState {
        address owner;
        uint160 sqrtPriceX96;
        uint256 priceX96;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int24 currentTick;
        uint256 amount0;
        uint256 amount1;
        uint256 balance0;
        uint256 balance1;
        uint256 newTokenId;
        int24 twapTick;
    }

    /**
     * @notice Adjust token (must be in correct state)
     * Can be called only from configured operator account
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function adjust(AdjustParams calldata params) external {
        if (msg.sender != operator) {
            revert Unauthorized();
        }

        PositionConfig storage config = configs[params.tokenId];
        if (config.lowerTickDelta == config.upperTickDelta) {
            revert NotConfigured();
        }

        AdjustState memory state;

        // check if in valid range for move range
        (
            ,
            ,
            state.token0,
            state.token1,
            state.fee,
            state.tickLower,
            state.tickUpper,
            state.liquidity,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(params.tokenId);

        IUniswapV3Pool pool = _getPool(state.token0, state.token1, state.fee);
        (state.sqrtPriceX96, state.currentTick, , , , , ) = pool.slot0();
        if (
            state.currentTick < state.tickLower - config.lowerTickLimit ||
            state.currentTick >= state.tickUpper + config.upperTickLimit
        ) {
           
            _doTWAPPriceCheck(pool, state.currentTick, TWAPSeconds, maxTWAPTickDifference);

            // calculate with current pool price
            state.priceX96 = FullMath.mulDiv(
                state.sqrtPriceX96,
                state.sqrtPriceX96,
                Q96
            );

            uint256 minAmountOut = _getMinAmountOut(params.amountIn, state.priceX96, config.maxSlippageX64, params.swap0To1);
            int24 tickSpacing = _getTickSpacing(state.fee);

            state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);

            // includes negative modulus fix
            int24 baseTick = state.currentTick - (((state.currentTick % tickSpacing) + tickSpacing) % tickSpacing);

            // check if new range same as old range
            if (baseTick + config.lowerTickDelta == state.tickLower &&
                baseTick + config.upperTickDelta == state.tickUpper) {
                revert SameRange();
            }

            // remove position liquidity
            if (state.liquidity > 0) {
                nonfungiblePositionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(
                        params.tokenId,
                        state.liquidity,
                        0, // no slippage check needed 
                        0, // no slippage check needed 
                        params.deadline
                    )
                );
            }
            // get everything
            nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams(
                    params.tokenId,
                    address(this),
                    type(uint128).max,
                    type(uint128).max
                )
            );

            state.amount0 = IERC20(state.token0).balanceOf(address(this));
            state.amount1 = IERC20(state.token1).balanceOf(address(this));

            (state.amount0, state.amount1) = _removeAndSendFeeToOperator(params.takeFeeFrom0, (params.takeFeeFrom0 ? state.token0 : state.token1), state.amount0, state.amount1, state.priceX96, params.feeAmount, configs[params.tokenId].maxGasFeeRewardX64);
           
            // approve tokens
            if (state.amount0 > 0) {
                SafeERC20.safeApprove(IERC20(state.token0), address(v3Utils), state.amount0);
            }
            if (state.amount1 > 0) {
                SafeERC20.safeApprove(IERC20(state.token1), address(v3Utils), state.amount1);
            }
            
            (state.newTokenId,,,) = v3Utils.swapAndMint(V3Utils.SwapAndMintParams(
                IERC20(state.token0),
                IERC20(state.token1), 
                state.fee, 
                OZSafeCast.toInt24(baseTick + config.lowerTickDelta), // reverts if out of valid range
                OZSafeCast.toInt24(baseTick + config.upperTickDelta), // reverts if out of valid range
                state.amount0,
                state.amount1,
                state.owner,
                state.owner,
                params.deadline,
                params.swap0To1 ? IERC20(state.token0) : IERC20(state.token1),
                params.swap0To1 ? 0 : params.amountIn,
                params.swap0To1 ? 0 : minAmountOut,
                params.swap0To1 ? bytes("") : params.swapData,
                params.swap0To1 ? params.amountIn : 0,
                params.swap0To1 ? minAmountOut : 0,
                params.swap0To1 ? params.swapData : bytes(""),
                0, // no slippage check needed 
                0, // no slippage check needed 
                ""
            ));

            if (state.newTokenId == 0) {
                revert AdjustStateError();
            }

            // reset approvals not needed - v3Utils it our trusted contract and uses all approv
   
            // copy token config for new token
            configs[state.newTokenId] = config;

            emit PositionConfigured(
                state.newTokenId,
                config.lowerTickLimit,
                config.upperTickLimit,
                config.lowerTickDelta,
                config.upperTickDelta,
                config.maxSlippageX64,
                config.maxGasFeeRewardX64
            );

            emit RangeChanged(params.tokenId, state.newTokenId);

            // delete config for old position
            delete configs[params.tokenId];
            emit PositionConfigured(params.tokenId, 0, 0, 0, 0, 0, 0);
        } else {
            revert NotReady();
        }
    }

    // get tick spacing for fee tier (cached when possible)
    function _getTickSpacing(uint24 fee) internal view returns (int24) {
        if (fee == 10000) {
            return 200;
        } else if (fee == 3000) {
            return 60;
        } else if (fee == 500) {
            return 10;
        } else {
            int24 spacing = factory.feeAmountTickSpacing(fee);
            if (spacing <= 0) {
                revert NotSupportedFeeTier();
            }
            return spacing;
        }
    }
}
