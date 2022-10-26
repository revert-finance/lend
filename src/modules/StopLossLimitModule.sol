// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IModule.sol";
import "../NFTHolder.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";

contract StopLossModule is IModule, Ownable {

    // config changes
    event RewardUpdated(address account, uint64 totalRewardX64);

    uint128 constant Q64 = 2**64;

    // max reward
    uint64 constant public MAX_REWARD_X64 = uint64(Q64 / 100); // 1%

    // changable config values
    uint64 public totalRewardX64 = MAX_REWARD_X64; // 1%

    NFTHolder public immutable holder;
    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    uint8 public immutable blockTime;

    constructor(NFTHolder _holder, IUniswapV3Factory _factory, INonfungiblePositionManager _nonfungiblePositionManager, uint8 _blockTime) {
        holder = _holder;
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        blockTime = _blockTime;
    }

    /**
     * @notice Management method to lower reward (onlyOwner)
     * @param _totalRewardX64 new total reward (can't be higher than current total reward)
     */
    function setReward(uint64 _totalRewardX64) external onlyOwner {
        require(_totalRewardX64 <= totalRewardX64, ">totalRewardX64");
        totalRewardX64 = _totalRewardX64;
        emit RewardUpdated(msg.sender, _totalRewardX64);
    }

    struct PositionConfig {
        
        IUniswapV3Pool pool;

        // limit values
        int24 stopLossTick; // if type(int24).max or type(int24).min
        int24 limitTick; // if type(int24).max or type(int24).min

        // number of blocks to elapse until max gas fee reward is payed
        uint8 blockCountUntilMax;

        // percentage of position value which is rewarded to executor (is increased linearly until maxGasFeeReward per block)
        uint8 minGasFeeReward0;
        uint8 maxGasFeeReward0;
        uint8 minGasFeeReward1;
        uint8 maxGasFeeReward1;
    }

    mapping (uint => PositionConfig) positionConfigs;

    /// @notice params for execute()
    struct ExecuteParams {
        // tokenid to autocompound
        uint256 tokenId;
        bool isLimit;
        bytes swapData;
    }

    // function which can by anyone when position is in certain state
    function execute(ExecuteParams memory params) external returns (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) {

        PositionConfig storage config = positionConfigs[params.tokenId];

        // must be active in module
        if (address(config.pool) == address(0)) {
            revert NotFound();
        }
        
        // get current tick
        (,int24 tick,,,,,) = config.pool.slot0();

        bool isAbove = config.isLimit0; // TODO implemetn condition
        uint8 blocks = _checkNumberOfBlocks(config.pool, config.blockCountUntilMax, tick, params.isLimit ? config.limitTick : config.stopLossTick, isAbove);

        // if the last block was not in correct condition - stop
        if (blocks == 0) {
            revert NotInCondition();
        }

        // get position info
        (,,,,,,, uint128 liquidity, , , , ) =  nonfungiblePositionManager.positions(params.tokenId);

        // decrease liquidity for given position (one sided only) - and return fees as well
        (uint256 amount0, uint256 amount1) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(params.tokenId, liquidity, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, address(this)));

        if (params.isLimit) {
            // limit order
            if (tick < tickLower && config.limitSide0 || tick > tickUpper && !config.limitSide0) {
                
                

            }
        } else {
            // stop loss order

        }

        nonfungiblePositionManager.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(params.tokenId, amount0, amount1, 0, 0, block.timestamp));

        // TODO calculate fees

        address owner = ;
        SafeERC20.safeTransfer(token0, to, value);
    }

    function _checkNumberOfBlocks(IUniswapV3Pool pool, uint8 maxNumberOfBlocks, int24 currentTick, int24 checkTick, bool isAbove) internal returns (uint8) {

        uint32[] memory secondsAgos = new uint32[](maxNumberOfBlocks);
        secondsAgos[0] = 0; // from (before)
        uint8 i;
        for (; i <= maxNumberOfBlocks; i++) {
            secondsAgos[i] = i * blockTime;
        }

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            i = 0;
            for (; i < maxNumberOfBlocks; i++) {
                if (isAbove) {
                    if (tickCumulatives[i] - tickCumulatives[i + 1] <= checkTick) {
                        return i;
                    }
                } else {
                    if (tickCumulatives[i] - tickCumulatives[i + 1] >= checkTick) {
                        return i;
                    }
                }
            }
        } catch {
            revert NotEnoughHistory();
        }

        return maxNumberOfBlocks;
    }

    function addToken(uint256 tokenId, address, bytes calldata data) override external  {

        (, , address token0, address token1, uint24 fee, , , , , , , ) = nonfungiblePositionManager.positions(tokenId);

        address pool = PoolAddress.computeAddress(
                address(factory),
                PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})
            );

        PositionConfig memory config = abi.decode(data, (PositionConfig));
        config.pool = IUniswapV3Pool(pool);
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