// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "../NFTHolder.sol";
import "./IStopLossLimitModule.sol";
import "./Module.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import 'v3-core/libraries/FullMath.sol';

import 'v3-periphery/libraries/PoolAddress.sol';

contract StopLossLimitModule is IStopLossLimitModule, Module {

    // how many intervals to check
    uint8 constant CHECK_INTERVALS = 16; // TODO what value to take here?

    // max reward
    uint64 constant public MAX_REWARD_X64 = uint16(Q16 / 1000); // 0.1%

    // changable config values
    uint64 public protocolRewardX64 = MAX_REWARD_X64; // 0.1%

    constructor(NFTHolder _holder, address _swapRouter) Module(_holder, _swapRouter) {
    }

    /**
     * @notice Management method to lower reward (onlyOwner)
     * @param _protocolRewardX64 new total reward (can't be higher than current total reward)
     */
    function setReward(uint64 _protocolRewardX64) external onlyOwner {
        require(_protocolRewardX64 <= protocolRewardX64, ">protocolRewardX64");
        protocolRewardX64 = _protocolRewardX64;
        emit RewardUpdated(msg.sender, _protocolRewardX64);
    }

    /**
     * @notice Management method to withdraw left tokens (protocol fee) (onlyOwner)
     * @param token address of erc-20 token
     */
    function withdrawBalance(address token) external onlyOwner {
        uint balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            SafeERC20.safeTransfer(IERC20(token), msg.sender, balance);
        }
    }

    struct PositionConfig {

        // is limit order actvated
        bool isLimit;

        // is stoploss order activated
        bool isStopLoss;

        // token0 is received when limit order
        bool token0Limit;

        // number of seconds to elapse until max reward payed
        uint16 secondsUntilMax;

        // percentage of position value which is rewarded to executor (is increased linearly until maxReward per second)
        uint16 minRewardX16;
        uint16 maxRewardX16;


        // TODO manage TWAP params globally or per position??

        // max ticks current tick may be from twap to be considered valid
        uint32 ticksFromTWAP;
        // seconds to be used for TWAP check
        uint32 TWAPSeconds;
        // max swap price difference Q16 ratio from current price
        uint16 maxSwapDifferenceX16;

        // min amount out - for stop loss swap
        uint minAmountOut;
    }

    mapping (uint => PositionConfig) positionConfigs;

    /// @notice params for execute()
    struct ExecuteParams {
        // tokenid to process
        uint256 tokenId;

        // if its a stop loss order - include swap data
        bytes swapData;
    }

    // function which can be executed by anyone when position is in certain state
    function execute(ExecuteParams memory params) external returns (uint256 reward0, uint256 reward1) {

        PositionConfig storage config = positionConfigs[params.tokenId];

        // must be active in module
        if (config.isLimit || config.isStopLoss) {
            revert NotFound();
        }

        // get position info
        (,,address token0, address token1, uint24 fee,int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) =  nonfungiblePositionManager.positions(params.tokenId);

        IUniswapV3Pool pool = _getPool(token0, token1, fee);

        // TODO deduplicate this call - it is called later on
        (,int24 tick,,,,,) = pool.slot0();

        // quick check if limit or stoploss activatable
        bool isLimit = config.isLimit && (config.token0Limit && tick < tickLower || !config.token0Limit && tick > tickUpper);
        bool isStopLoss = !isLimit && config.isStopLoss && (config.token0Limit && tick > tickLower || !config.token0Limit && tick < tickUpper);

        if (!isLimit && !isStopLoss) {
            revert NotInCondition();
        }

        // check how many intervals already are in correct state
        bool isAbove = !config.token0Limit && isLimit || config.token0Limit && isStopLoss;
        int24 criticalTick = isAbove ? tickUpper : tickLower;
        uint8 blocks = _checkNumberOfBlocks(pool, config.secondsUntilMax, criticalTick, isAbove);

        // if the last block was not in correct condition - stop
        if (blocks == 0) {
            revert NotInCondition();
        }

        // decrease liquidity for given position (one sided only) - and return fees as well
        (uint256 amount0, uint256 amount1) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(params.tokenId, liquidity, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, address(this)));

        // if stop loss order - swap to other token
        if (isStopLoss) {

            if (params.swapData.length == 0) {
                revert MissingSwapData();
            }

            uint swapAmount = isAbove ? amount0 : amount1;

            (uint amountOutMin,) = _validateSwap(isAbove, swapAmount, pool, config.TWAPSeconds, config.ticksFromTWAP, config.maxSwapDifferenceX16);
            (uint amountInDelta, uint256 amountOutDelta) = _swap(isAbove ? IERC20(token0) : IERC20(token1), isAbove ? IERC20(token1) : IERC20(token0), swapAmount, amountOutMin, params.swapData);

            amount0 = isAbove ? amount0 - amountInDelta : amount0 + amountOutDelta;
            amount1 = isAbove ? amount1 + amountOutDelta : amount1 - amountInDelta;
        }
        
        // calculate dynamic reward factor depending on how many blocks have passed
        uint rewardX16 = (config.minRewardX16 + (config.maxRewardX16 - config.minRewardX16) * blocks / CHECK_INTERVALS);
        
        reward0 = amount0 * rewardX16 / Q16;
        reward1 = amount1 * rewardX16 / Q16;

        uint protocolReward0 = amount0 * protocolRewardX64 / Q64;
        uint protocolReward1 = amount1 * protocolRewardX64 / Q64;

        // send final tokens to position owner
        address owner = holder.tokenOwners(params.tokenId);
        SafeERC20.safeTransfer(IERC20(token0), owner, amount0 - reward0 - protocolReward0);
        SafeERC20.safeTransfer(IERC20(token1), owner, amount1 - reward1 - protocolReward1);

        // send rewards to executor
        SafeERC20.safeTransfer(IERC20(token0), msg.sender, reward0);
        SafeERC20.safeTransfer(IERC20(token1), msg.sender, reward1);

        // keep rest in contract (for owner withdrawal)

        // log event
        emit Executed(msg.sender, isLimit, params.tokenId, amount0 - reward0 - protocolReward0, amount1 - reward1 - protocolReward1, reward0, reward1, token0, token1);
    }

    function _checkNumberOfBlocks(IUniswapV3Pool pool, uint16 secondsUntilMax, int24 checkTick, bool isAbove) internal view returns (uint8) {

        uint16 blockTime = secondsUntilMax / CHECK_INTERVALS; 

        uint32[] memory secondsAgos = new uint32[](CHECK_INTERVALS + 1);
        uint8 i;
        for (; i <= CHECK_INTERVALS; i++) {
            secondsAgos[i] = i * blockTime;
        }

        int56 checkTickMul = int16(blockTime) * checkTick;

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            i = 0;
            for (; i < CHECK_INTERVALS; i++) {
                if (isAbove) {
                    if ((tickCumulatives[i] - tickCumulatives[i + 1]) <= checkTickMul) {
                        return i;
                    }
                } else {
                    if ((tickCumulatives[i] - tickCumulatives[i + 1]) >= checkTickMul) {
                        return i;
                    }
                }
            }
        } catch {
            revert NotEnoughHistory();
        }

        return CHECK_INTERVALS;
    }

    function addToken(uint256 tokenId, address, bytes calldata data) override external  {
        PositionConfig memory config = abi.decode(data, (PositionConfig));

        if (config.secondsUntilMax < CHECK_INTERVALS) {
            revert ConfigError();
        }

        positionConfigs[tokenId] = config;
    }

    function withdrawToken(uint256 tokenId, address) override external {
         delete positionConfigs[tokenId];
    }

    function checkOnCollect(uint256, address, uint, uint) override external pure returns (bool) {
        return true;
    }
}

error NotFound();
error NotConfigured();
error NotEnoughHistory();
error NotInCondition();
error MissingSwapData();
error ConfigError();