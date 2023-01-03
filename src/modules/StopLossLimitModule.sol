// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Module.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import 'v3-core/libraries/FullMath.sol';

/// @title StopLossLimitModule
/// @notice Lets a v3 position to be automatically removed or swapped to the oposite token when it reaches a certain tick. 
/// A revert controlled bot is responsible for the execution of optimized swaps
/// Non-swap or pool-swap operations can be called by anyone
contract StopLossLimitModule is Module {

    // events
    event SwapRouterUpdated(address account, address swapRouter);
    event RewardUpdated(address account, uint64 protocolRewardX64);
    event Executed(
        address account,
        bool isSwap,
        uint256 tokenId,
        uint256 amountReturned0,
        uint256 amountReturned1,
        address token0,
        address token1
    );

    // errors 
    error NotFound();
    error NoLiquidity();
    error NotConfigured();
    error NotInCondition();
    error MissingSwapData();
    error OnlyOwnerCanSwap();
    error ConfigError();

    uint32 public maxTWAPTickDifference = 100; // 1%
    uint32 public TWAPSeconds = 60;
    uint64 public protocolRewardX64 = uint64(Q64 / 200); // 0.5%
    address public swapRouter;

    bool public immutable override needsCheckOnCollect = false;

    constructor(NFTHolder _holder, address _swapRouter) Module(_holder) {
        swapRouter = _swapRouter;
    }

    struct PositionConfig {
        // should swap token to other token when triggered
        bool token0Swap;
        bool token1Swap;

        // should a swap in the same pool be allowed (for decentralized keepers)
        bool allowPoolSwap;

        // max price difference from current pool price for swap / Q64
        uint64 token0SlippageX64;
        uint64 token1SlippageX64;

        // when should action be triggered
        int24 token0TriggerTick;
        int24 token1TriggerTick;
    }

    mapping (uint => PositionConfig) positionConfigs;

    /// @notice params for execute()
    struct ExecuteParams {
        // tokenid to process
        uint256 tokenId;

        // if its a swap order and caller is contract owner - can include optimized swap data
        bytes swapData;
    }

    struct ExecuteState {
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
        uint protocolReward0;
        uint protocolReward1;
        uint swapAmount;
        int24 tick;
        bool isSwap;
        bool isAbove;
        bool isContractOwner;
        address owner;
    }

    /**
     * @notice Management method to change swap router (onlyOwner)
     * @param _swapRouter new swap router
     */
    function setSwapRouter(address _swapRouter) external onlyOwner {
        require(_swapRouter != address(0), "!swapRouter");
        swapRouter = _swapRouter;
        emit SwapRouterUpdated(msg.sender, _swapRouter);
    }

    /**
     * @notice Management method to lower reward (onlyOwner)
     * @param _protocolRewardX64 new reward (can't be higher than current reward)
     */
    function setReward(uint64 _protocolRewardX64) external onlyOwner {
        require(_protocolRewardX64 <= protocolRewardX64, ">protocolRewardX64");
        protocolRewardX64 = _protocolRewardX64;
        emit RewardUpdated(msg.sender, _protocolRewardX64);
    }

    /**
     * @notice Withdraws token balance for a address and token
     * @param token Address of token to withdraw
     * @param to Address to send t
     */
    function withdrawBalance(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            _transferToken(to, IERC20(token), balance, true);
        }
    }


    // function which can be executed by owner only (atm) when position is in certain state
    function execute(ExecuteParams memory params) external {

        ExecuteState memory state;

        state.isContractOwner = owner() == msg.sender;

        PositionConfig storage config = positionConfigs[params.tokenId];

        // get position info
        (,,state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity, , , , ) =  nonfungiblePositionManager.positions(params.tokenId);

        if (state.liquidity == 0) {
            revert NoLiquidity();
        }

        state.pool = _getPool(state.token0, state.token1, state.fee);
        (,state.tick,,,,,) = state.pool.slot0();

        // not triggered
        if (config.token0TriggerTick <= state.tick && state.tick <= config.token1TriggerTick) {
            revert NotInCondition();
        }
    
        // check how many intervals already are in correct state
        state.isAbove = state.tick > config.token1TriggerTick;
        state.isSwap = !state.isAbove && config.token0Swap || state.isAbove && config.token1Swap;
       
        // decrease full liquidity for given position (one sided only) - and return fees as well
        (state.amount0, state.amount1, ) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(params.tokenId, state.liquidity, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, false, address(this), ""));

        // swap to other token
        if (state.isSwap) {
            if (params.swapData.length == 0 && !config.allowPoolSwap) {
                revert MissingSwapData();
            }
            if (params.swapData.length > 0 && !state.isContractOwner) {
                revert OnlyOwnerCanSwap();
            }

            state.swapAmount = state.isAbove ? state.amount1 : state.amount0;
            
            // checks if price in valid oracle range and calculates amountOutMin
            (state.amountOutMin,,) = _validateSwap(!state.isAbove, state.swapAmount, state.pool, TWAPSeconds, maxTWAPTickDifference, state.isAbove ? config.token1SlippageX64 : config.token0SlippageX64);

            if (params.swapData.length > 0) {
                (state.amountInDelta, state.amountOutDelta) = _swap(swapRouter, state.isAbove ? IERC20(state.token1) : IERC20(state.token0), state.isAbove ? IERC20(state.token0) : IERC20(state.token1), state.swapAmount, state.amountOutMin, params.swapData);
            } else {
                state.amountInDelta = state.swapAmount;
                state.amountOutDelta = _poolSwap(state.pool, state.token0, state.token1, state.fee, !state.isAbove, state.swapAmount, state.amountOutMin);
            }

            state.amount0 = state.isAbove ? state.amount0 + state.amountOutDelta : state.amount0 - state.amountInDelta;
            state.amount1 = state.isAbove ? state.amount1 - state.amountInDelta : state.amount1 + state.amountOutDelta;
        }
     
        state.protocolReward0 = state.amount0 * protocolRewardX64 / Q64;
        state.protocolReward1 = state.amount1 * protocolRewardX64 / Q64;


        // send final tokens to position owner - if any
        state.owner = holder.tokenOwners(params.tokenId);
        if (state.amount0 - state.protocolReward0 > 0) {
            _transferToken(state.owner, IERC20(state.token0), state.amount0 - state.protocolReward0, true);
        }
        if (state.amount1 - state.protocolReward1 > 0) {
            _transferToken(state.owner, IERC20(state.token1), state.amount1 - state.protocolReward1, true);
        }
        
        // if caller not contract owner - directly send rewards - otherwise keep in contract for withdrawal when needed
        if (!state.isContractOwner) {
            if (state.protocolReward0 > 0) {
                _transferToken(msg.sender, IERC20(state.token0), state.protocolReward0, true);
            }
            if (state.protocolReward1 > 0) {
                _transferToken(msg.sender, IERC20(state.token1), state.protocolReward1, true);
            }
        }

        // log event
        emit Executed(msg.sender, state.isSwap, params.tokenId, state.amount0 - state.protocolReward0, state.amount1 - state.protocolReward1, state.token0, state.token1);
    }

    function addToken(uint256 tokenId, address, bytes calldata data) override onlyHolder external {
        PositionConfig memory config = abi.decode(data, (PositionConfig));

        (,,address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,,,,,) =  nonfungiblePositionManager.positions(tokenId);

        // trigger ticks have to be on the correct side of position range
        if (tickLower <= config.token0TriggerTick || tickUpper >= config.token1TriggerTick) {
            revert ConfigError();
        }

        IUniswapV3Pool pool = _getPool(token0, token1, fee);

        // prepare pool to be ready with enough observations
        (,,,,uint16 observationCardinalityNext,,) = pool.slot0();
        if (observationCardinalityNext < TWAPSeconds) {
            pool.increaseObservationCardinalityNext(uint16(TWAPSeconds)); // TODO what number to use here - can be less than TWAPSeconds
        }
        
        positionConfigs[tokenId] = config;
    }

    function withdrawToken(uint256 tokenId, address) override onlyHolder external {
         delete positionConfigs[tokenId];
    }
}