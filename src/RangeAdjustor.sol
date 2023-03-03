// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";

import "v3-periphery/libraries/LiquidityAmounts.sol";

import "./V3Utils.sol";

//TODO remove
import "forge-std/console.sol";


/// @title RangeAdjustor
/// @notice Allows operator of RangeAdjustor contract (Revert controlled bot) to change range for configured positions
/// Positions need to be approved for the contract and configured with setConfig method
contract RangeAdjustor is Ownable, IERC721Receiver {

    error Unauthorized();
    error WrongContract();
    error InvalidConfig();
    error NotSupportedFeeTier();
    error AdjustStateError();
    error NotConfigured();

    event PositionConfigured(uint256 indexed tokenId);
    event RangeChanged(uint256 indexed oldTokenId, uint256 indexed newTokenId);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);

    uint256 private constant Q64 = 2**64; 
    uint256 private constant Q96 = 2**96; 

    V3Utils public immutable v3Utils;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;

    // to store current token id while doing adjust()
    uint256 private processingTokenId;

    // operator
    address public operator;

    struct PositionConfig {
        int24 lowerTickLimit; // if negative also in-range positions may be adjusted
        int24 upperTickLimit; // if negative also in-range positions may be adjusted

        int24 lowerTickDelta; // must be 0 or a negative multiple of tick spacing
        int24 upperTickDelta; // must greater than 0 and positive multiple of tick spacing

        uint64 maxSlippageX64; // max allowed swap slippage including fees, price impact and slippage - from current pool price (to be sure revert bot can not do silly things)
        uint64 maxGasFeeRewardX64; // max allowed token percentage to be available for covering gas cost of operator (operator chooses which one of the two tokens to receive)
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public configs;

    constructor(V3Utils _v3Utils, address _swapRouter, address _operator)  {
        v3Utils = _v3Utils;
        INonfungiblePositionManager npm = _v3Utils.nonfungiblePositionManager();
        nonfungiblePositionManager = npm;
        factory = IUniswapV3Factory(npm.factory());
        operator = _operator;
        emit OperatorChanged(address(0), _operator);
    }

    /**
     * @notice Admin function to change operator address
     */
    function setOperator(address _operator) onlyOwner external {
        emit OperatorChanged(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Sets config for a given NFT - must be owner
     */
    function setConfig(uint256 tokenId, PositionConfig calldata config) external {

        if (config.lowerTickDelta > 0 || config.upperTickDelta <= 0) {
            revert InvalidConfig();
        }

        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }
        configs[tokenId] = config;

        emit PositionConfigured(tokenId);
    }

    struct AdjustParams {
        uint256 tokenId;
        bool swap0To1;
        uint256 amountIn; // if this is set to 0 no swap happens
        bytes swapData;
        uint256 deadline; // for uniswap operations
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
    }

    /**
     * @notice Adjust token (must be in correct state)
     * Can be called only from configured operator account
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function adjust(AdjustParams calldata params) external {
        // if already in an adjustment - do not allow reentrancy
        if (processingTokenId != 0) {
            revert AdjustStateError();
        }

        if (msg.sender != operator) {
            revert Unauthorized();
        }

        PositionConfig storage config = configs[params.tokenId];
        if (config.upperTickDelta == 0) {
            revert NotConfigured();
        }

        AdjustState memory state;

        // check if in valid range for move range
        (,,state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity,,,,) = nonfungiblePositionManager.positions(params.tokenId);

        IUniswapV3Pool pool = _getPool(state.token0, state.token1, state.fee);
        (state.sqrtPriceX96, state.currentTick,,,,,) = pool.slot0();
        if (state.currentTick < state.tickLower - config.lowerTickLimit || state.currentTick >= state.tickUpper + config.upperTickLimit) {

            // calculate with current pool price 
            state.priceX96 = FullMath.mulDiv(state.sqrtPriceX96, state.sqrtPriceX96, Q96);
            uint256 minAmountOut = FullMath.mulDiv(Q64 - config.maxSlippageX64, params.swap0To1 ? FullMath.mulDiv(params.amountIn, state.priceX96, Q96) : FullMath.mulDiv(params.amountIn, Q96, state.priceX96), Q64);
            int24 tickSpacing = _getTickSpacing(state.fee);

            state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);

            // includes negative modulus fix
            int24 baseTick = state.currentTick - (((state.currentTick % tickSpacing) + tickSpacing) % tickSpacing);

            // before starting process - set context id
            processingTokenId = params.tokenId;

            // change range with v3utils
            bytes memory data = abi.encode(V3Utils.Instructions(
                V3Utils.WhatToDo.CHANGE_RANGE,
                params.swap0To1 ? state.token1 : state.token0,
                params.swap0To1 ? params.amountIn : 0,
                params.swap0To1 ? minAmountOut : 0,
                params.swap0To1 ? params.swapData : bytes(""),
                params.swap0To1 ? 0 : params.amountIn,
                params.swap0To1 ? 0 : minAmountOut,
                params.swap0To1 ? bytes("") : params.swapData,
                type(uint128).max,
                type(uint128).max,
                state.fee,
                baseTick + config.lowerTickDelta,
                baseTick + config.upperTickDelta,
                state.liquidity,
                0,
                0,
                params.deadline,
                address(this), // receive leftover tokens to grab fees - and then return rest to owner
                address(this), // recieve the new NFT to register config and then resend
                false,
                "",
                abi.encode(params.tokenId)
            ));
            nonfungiblePositionManager.safeTransferFrom(state.owner, address(v3Utils), params.tokenId, data);
        
            // check if processingTokenId was updated
            state.newTokenId = processingTokenId;
            if (state.newTokenId == params.tokenId) {
                revert AdjustStateError();
            }

            // copy token config for new token
            configs[state.newTokenId] = config;
            emit PositionConfigured(state.newTokenId);

            // get new token liquidity
            (,,,,,state.tickLower,state.tickUpper,state.liquidity,,,,) = nonfungiblePositionManager.positions(state.newTokenId);

            // balances (leftover tokens from change range operation
            state.balance0 = IERC20(state.token0).balanceOf(address(this));
            state.balance1 = IERC20(state.token1).balanceOf(address(this));

            // position value (position has no fees it has been just created - so only liquidity)
            (state.amount0, state.amount1) = LiquidityAmounts.getAmountsForLiquidity(state.sqrtPriceX96, TickMath.getSqrtRatioAtTick(state.tickLower), TickMath.getSqrtRatioAtTick(state.tickUpper), state.liquidity);

            // max fee in feeToken
            uint256 totalFeeTokenAmount = params.takeFeeFrom0 ? state.balance0 + state.amount0 + FullMath.mulDiv(state.balance1 + state.amount1, Q96, state.priceX96) : state.balance1 + state.amount1 + FullMath.mulDiv(state.balance0 + state.amount0, state.priceX96, Q96);

            // calculate max permited fee amount for this position
            uint256 maxFeeAmount = FullMath.mulDiv(totalFeeTokenAmount, configs[params.tokenId].maxGasFeeRewardX64, Q64);

            // calculate fee amount which can be sent.. it can be less.. so it is the operators responsibility to do correct swap
            uint256 effectiveFeeAmount = params.feeAmount > (params.takeFeeFrom0 ? state.balance0 : state.balance1) ? (params.takeFeeFrom0 ? state.balance0 : state.balance1) : params.feeAmount;
            if (effectiveFeeAmount > maxFeeAmount) {
                effectiveFeeAmount = maxFeeAmount;
            }

            // send fee to operator
            if (effectiveFeeAmount > 0) {
                IERC20(params.takeFeeFrom0 ? state.token0 : state.token1).transfer(operator, effectiveFeeAmount);
                if (params.takeFeeFrom0) {
                    state.balance0 -= effectiveFeeAmount;
                } else {
                    state.balance1 -= effectiveFeeAmount;
                }
            }

            // return leftover tokens to owner
            if (state.balance0 > 0) {
                IERC20(state.token0).transfer(state.owner, state.balance0);
            }
            if (state.balance1 > 0) {
                IERC20(state.token1).transfer(state.owner, state.balance1);
            }

            // send new position to owner
            nonfungiblePositionManager.safeTransferFrom(address(this), state.owner, state.newTokenId, "");

            emit RangeChanged(params.tokenId, state.newTokenId);

            // delete config for old position
            delete configs[params.tokenId];

            // processing of token is finished - reset this to 0
            processingTokenId = 0;
        }
    }

    // recieve new ERC-721 - if all validations pass this updates the processing token to the new token recieved
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        // only Uniswap v3 NFTs allowed
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }

        // get previous token id from contract state
        uint256 previousTokenId = processingTokenId;
        uint256 expectedProcessingTokenId = abi.decode(data, (uint256));

        // if not as expected - revert
        // this is important - it prevents from triggering onERC721Received by a malicious contract before the expected call
        if (previousTokenId == 0 || previousTokenId != expectedProcessingTokenId) {
            revert AdjustStateError();
        }
      
        // update current token
        processingTokenId = tokenId;

        return IERC721Receiver.onERC721Received.selector;
    }

    // get pool for token
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(address(factory), PoolAddress.getPoolKey(tokenA, tokenB, fee)));
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