// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";

import "./V3Utils.sol";

/// @title RangeAdjustor
/// @notice Allows operator of RangeAdjustor contract (Revert controlled bot) to change range for configured positions
/// Positions need to be approved for the contract and configured with setConfig method
contract RangeAdjustor is Ownable {
    error Unauthorized();
    error WrongContract();
    error InvalidConfig();
    error NotSupportedFeeTier();
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
    event OperatorChanged(
        address indexed oldOperator,
        address indexed newOperator
    );

    uint256 private constant Q64 = 2 ** 64;
    uint256 private constant Q96 = 2 ** 96;

    V3Utils public immutable v3Utils;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;
    uint32 public immutable TWAPSeconds;

    // operator
    address public operator;

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

    
    constructor(V3Utils _v3Utils, address _operator, uint32 _TWAPSeconds) {
        v3Utils = _v3Utils;
        INonfungiblePositionManager npm = _v3Utils.nonfungiblePositionManager();
        nonfungiblePositionManager = npm;
        factory = IUniswapV3Factory(npm.factory());
        operator = _operator;
        TWAPSeconds = _TWAPSeconds;
        emit OperatorChanged(address(0), _operator);
    }

    /**
     * @notice Admin function to change operator address
     */
    function setOperator(address _operator) external onlyOwner {
        emit OperatorChanged(operator, _operator);
        operator = _operator;
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
        address operator;
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
            state.operator,
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
            // calculate with current pool price (TODO do we need a TWAP oracle here??)
            state.priceX96 = FullMath.mulDiv(
                state.sqrtPriceX96,
                state.sqrtPriceX96,
                Q96
            );

            uint256 minAmountOut = FullMath.mulDiv(
                Q64 - config.maxSlippageX64,
                params.swap0To1
                    ? FullMath.mulDiv(params.amountIn, state.priceX96, Q96)
                    : FullMath.mulDiv(params.amountIn, Q96, state.priceX96),
                Q64
            );
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
                        0,
                        0,
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

            // max fee in feeToken
            uint256 totalFeeTokenAmount = params.takeFeeFrom0 ? state.amount0 + FullMath.mulDiv(state.amount1, Q96, state.priceX96) : state.amount1 + FullMath.mulDiv(state.amount0, state.priceX96, Q96);

            // calculate max permited fee amount for this position
            uint256 maxFeeAmount = FullMath.mulDiv(totalFeeTokenAmount, configs[params.tokenId].maxGasFeeRewardX64, Q64);

            // calculate fee amount which can be sent.. it can be less.. so it is the operators responsibility to do correct swap
            uint256 effectiveFeeAmount = params.feeAmount > (params.takeFeeFrom0 ? state.amount0 : state.amount1) ? (params.takeFeeFrom0 ? state.amount0 : state.amount1) : params.feeAmount;
            if (effectiveFeeAmount > maxFeeAmount) {
                effectiveFeeAmount = maxFeeAmount;
            }

            // send fee to operator
            SafeERC20.safeTransfer(IERC20(params.takeFeeFrom0 ? state.token0 : state.token1), operator, effectiveFeeAmount);

            // calculate left tokens to add
            if (params.takeFeeFrom0) {
                state.amount0 -= effectiveFeeAmount;
            } else {
                state.amount1 -= effectiveFeeAmount;
            }
           
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
                0, // no add slippage check needed
                0, // no add slippage check needed
                ""
            ));

            if (state.newTokenId == 0) {
                revert AdjustStateError();
            }

            //TODO reset approvals needed? v3Utils it our trusted contract after all
   
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

    // get pool for token
    function _getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal view returns (IUniswapV3Pool) {
        return
            IUniswapV3Pool(
                PoolAddress.computeAddress(
                    address(factory),
                    PoolAddress.getPoolKey(tokenA, tokenB, fee)
                )
            );
    }

    // get tick spacing for fee tier
    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 10000) {
            return 200;
        } else if (fee == 3000) {
            return 60;
        } else if (fee == 500) {
            return 10;
        } else if (fee == 100) {
            return 1;
        } else {
            revert NotSupportedFeeTier();
        }
    }
}
