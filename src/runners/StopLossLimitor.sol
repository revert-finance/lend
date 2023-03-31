// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Runner.sol";

import "forge-std/console.sol";

/// @title StopLossLimitor
/// @notice Lets a v3 position to be automatically removed or swapped to the oposite token when it reaches a certain tick. 
/// A revert controlled bot is responsible for the execution of optimized swaps
contract StopLossLimitor is Runner {

    error Unauthorized();
    error NotConfigured();
    error NotReady();
    error SwapWrong();

    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        uint64 maxSlippageX64,
        uint64 maxGasFeeRewardX64
    );
    event StopLossLimitExecuted(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    struct PositionConfig {

        // is this position active
        bool isActive;

        // should swap token to other token when triggered
        bool token0Swap;
        bool token1Swap;

        // when should action be triggered (when this tick is reached - allow execute) - must be on correct side of position
        int24 token0TriggerTick;
        int24 token1TriggerTick;

        uint64 maxSlippageX64; // max allowed swap slippage including fees, price impact and slippage - from current pool price (to be sure revert bot can not do silly things)
        uint64 maxGasFeeRewardX64; // max allowed token percentage to be available for covering gas cost of operator (operator chooses which one of the two tokens to receive after swap)
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public configs;

    constructor(V3Utils _v3Utils, address _operator, uint32 _TWAPSeconds, uint16 _maxTWAPTickDifference) Runner(_v3Utils, _operator, _TWAPSeconds, _maxTWAPTickDifference) {
    }

    /**
     * @notice Sets config for a given NFT - must be owner
     * To disable a position set isActive to false (or reset everything to default value)
     */
    function setConfig(uint256 tokenId, PositionConfig calldata config) external {
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        if (config.isActive) {
            // trigger ticks have to be on the correct side of position range
            (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nonfungiblePositionManager.positions(tokenId);
            if (tickLower <= config.token0TriggerTick || tickUpper > config.token1TriggerTick) {
                revert InvalidConfig();
            }
        }
        
        configs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.token0Swap,
            config.token1Swap,
            config.token0TriggerTick,
            config.token1TriggerTick,
            config.maxSlippageX64,
            config.maxGasFeeRewardX64
        );
    }

    struct RunParams {
        uint256 tokenId; // tokenid to process
        uint256 amountIn; // if its a swap order - how much to swap
        bytes swapData; // if its a swap order - must include swap data
        uint256 deadline; // for uniswap operations - operator promises fair value
        uint256 feeAmount; // fee amount requested from available token depending on config (swap or not)
    }

    struct RunState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 amountOutMin;
        uint256 amountInDelta;
        uint256 amountOutDelta;
        IUniswapV3Pool pool;
        uint256 protocolReward0;
        uint256 protocolReward1;
        uint256 swapAmount;
        int24 tick;
        bool isSwap;
        bool isAbove;
        address owner;
        uint160 sqrtPriceX96;
        uint256 priceX96;
        uint256 minAmountOut;
    }

    /**
     * @notice Adjust token (must be in correct state)
     * Can be called only from configured operator account
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function run(RunParams calldata params) external {
        if (msg.sender != operator) {
            revert Unauthorized();
        }

        PositionConfig storage config = configs[params.tokenId];
        if (!config.isActive) {
            revert NotConfigured();
        }

        RunState memory state;

        // get position info
        (,,state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity, , , , ) = nonfungiblePositionManager.positions(params.tokenId);
        state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);

        state.pool = _getPool(state.token0, state.token1, state.fee);
        (state.sqrtPriceX96,state.tick,,,,,) = state.pool.slot0();
        state.priceX96 = FullMath.mulDiv(state.sqrtPriceX96, state.sqrtPriceX96, Q96);

        if (config.token0TriggerTick <= state.tick && state.tick <= config.token1TriggerTick) {
            revert NotReady();
        }

        state.isAbove = state.tick > config.token1TriggerTick;
        state.isSwap = !state.isAbove && config.token0Swap || state.isAbove && config.token1Swap;

        if (state.isSwap && params.swapData.length == 0 || !state.isSwap && params.swapData.length > 0) {
            revert SwapWrong();
        }

        _doTWAPPriceCheck(state.pool, state.tick, TWAPSeconds, maxTWAPTickDifference);

        if (state.isSwap) {
            state.minAmountOut = _getMinAmountOut(params.amountIn, state.priceX96, config.maxSlippageX64, !state.isAbove);
        }        

        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            state.isSwap ? (state.isAbove ? state.token0 : state.token1) : address(0),
            0,
            0,
            state.isSwap ? (state.isAbove ? 0 : params.amountIn) : 0,
            state.isSwap ? (state.isAbove ? 0 : state.minAmountOut) : 0,
            state.isSwap ? (state.isAbove ? bytes("") : params.swapData) : bytes(""),
            state.isSwap ? (state.isAbove ? params.amountIn : 0) : 0,
            state.isSwap ? (state.isAbove ? state.minAmountOut : 0) : 0,
            state.isSwap ? (state.isAbove ? params.swapData : bytes("")) : bytes(""),
            type(uint128).max,
            type(uint128).max,
            0,
            0,
            0,
            state.liquidity,
            0,
            0,
            params.deadline,
            address(this), // recieve tokens to this contract so fee can be collected
            state.owner, // no nft is minted so this doesn't matter
            false,
            "",
            ""
        );

        // initiate v3utils flow (can be replaced with temporary operator assignment)
        nonfungiblePositionManager.safeTransferFrom(
            state.owner,
            address(v3Utils),
            params.tokenId,
            abi.encode(inst)
        );

        // tokens are now available
        state.amount0 = IERC20(state.token0).balanceOf(address(this));
        state.amount1 = IERC20(state.token1).balanceOf(address(this));

        bool takeFeeFrom0 = !state.isAbove && !state.isSwap || state.isAbove && state.isSwap;

        (state.amount0, state.amount1) = _removeAndSendFeeToOperator(takeFeeFrom0, (takeFeeFrom0 ? state.token0 : state.token1), state.amount0, state.amount1, state.priceX96, params.feeAmount, configs[params.tokenId].maxGasFeeRewardX64);

        // send rest to owner
        if (state.amount0 > 0) {
            SafeERC20.safeTransfer(IERC20(state.token0), state.owner, state.amount0);
        }
        if (state.amount1 > 0) {
            SafeERC20.safeTransfer(IERC20(state.token1), state.owner, state.amount1);
        }

        emit StopLossLimitExecuted(params.tokenId, state.amount0, state.amount1);

        config.isActive = false;
    }
}
