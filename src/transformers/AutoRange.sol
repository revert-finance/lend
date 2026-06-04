// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "v3-core/libraries/FullMath.sol";

import "../automators/Automator.sol";
import "../transformers/Transformer.sol";
import "../interfaces/pancake/IPancakeMasterChefV3Staker.sol";

/// @title AutoRange
/// @notice Allows operator of AutoRange contract (Revert controlled bot) to change range for configured positions
/// And optionally to autocompound position (depending on configuration)
/// Positions need to be approved (setApprovalForAll) for the contract and configured with configToken method
/// When executed a new position is created and automatically configured the same way as the original position
/// When a position is inside a Pancake MasterChef staker, transform is called through the staker.
contract AutoRange is Transformer, Automator, ReentrancyGuard, IPancakeMasterChefV3RewardTransformer {
    using SafeERC20 for IERC20;

    event RangeChanged(uint256 indexed oldTokenId, uint256 indexed newTokenId);
    event PositionConfigured(
        uint256 indexed tokenId,
        int32 lowerTickLimit,
        int32 upperTickLimit,
        int32 lowerTickDelta,
        int32 upperTickDelta,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        bool onlyFees,
        bool autoCompound,
        uint64 maxRewardX64,
        uint128 autoCompoundMin0,
        uint128 autoCompoundMin1,
        uint128 autoCompoundRewardMin
    );
    event AutoCompounded(
        uint256 indexed tokenId,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1
    );
    event LeftoverSent(uint256 indexed tokenId, address indexed token, address indexed to, uint256 amount);

    // config changes
    event CakeTokenSet(address indexed cakeToken);
    event RewardAnchorSet(address indexed anchorToken, uint256 anchorTokenMinBalance, bool active);
    event AutoCompoundRewardUpdated(address account, uint64 totalRewardX64);

    constructor(
        INonfungiblePositionManager _npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder
    )
        Automator(
            _npm, _operator, _withdrawer, _TWAPSeconds, _maxTWAPTickDifference, _universalRouter, _zeroxAllowanceHolder
        )
    {}

    // defines when and how a position can be changed by operator
    // when a position is adjusted config for the position is cleared and copied to the newly created position
    struct PositionConfig {
        // needs more than int24 because it can be [-type(uint24).max,type(uint24).max]
        int32 lowerTickLimit; // if negative also in-range positions may be adjusted / if 0 out of range positions may be adjusted
        int32 upperTickLimit; // if negative also in-range positions may be adjusted / if 0 out of range positions may be adjusted
        int32 lowerTickDelta; // this amount is added to current tick (floored to tickspacing) to define lowerTick of new position
        int32 upperTickDelta; // this amount is added to current tick (floored to tickspacing) to define upperTick of new position
        uint64 token0SlippageX64; // max price difference from current pool price for swap / Q64 for token0
        uint64 token1SlippageX64; // max price difference from current pool price for swap / Q64 for token1
        bool onlyFees; // if only fees maybe used for protocol reward
        bool autoCompound; // if this position can be autocompounded
        uint64 maxRewardX64; // max allowed reward percentage of fees or full position
        uint128 autoCompoundMin0; // min amount0 fees for fee autocompound execution
        uint128 autoCompoundMin1; // min amount1 fees for fee autocompound execution
        uint128 autoCompoundRewardMin; // min harvested CAKE when reward-compounding before an action
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public positionConfigs;

    /// @notice params for execute()
    struct ExecuteParams {
        uint256 tokenId;
        bool swap0To1;
        uint256 amountIn; // if this is set to 0 no swap happens
        bytes swapData;
        uint256 amountRemoveMin0; // min amount to be removed from liquidity
        uint256 amountRemoveMin1; // min amount to be removed from liquidity
        uint256 amountAddMin0; // min amount to be added to liquidity
        uint256 amountAddMin1; // min amount to be added to liquidity
        uint256 deadline; // for PancakeSwap v3 operations
        uint64 rewardX64; // which reward will be used for protocol, can be max configured amount (considering onlyFees)
    }

    struct ExecuteState {
        address owner;
        address realOwner;
        IUniswapV3Pool pool;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAmount0;
        uint256 feeAmount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint128 liquidity;
        uint256 protocolReward0;
        uint256 protocolReward1;
        uint256 amountOutMin;
        uint256 amountInDelta;
        uint256 amountOutDelta;
        uint256 newTokenId;
    }

    // reward handling for autocompound
    uint64 public constant MAX_REWARD_X64 = uint64(Q64 / 50); // 2%
    uint64 public constant REWARD_MAX_PRICE_DIFFERENCE_X64 = uint64(Q64 / 50); // 2%
    uint64 public totalRewardX64 = MAX_REWARD_X64; // 2%
    IERC20 public cakeToken;
    mapping(address => AnchorConfig) public rewardAnchors;

    enum RewardAction {
        RANGE,
        AUTO_COMPOUND
    }

    /// @notice Anchor token whitelist entry used when CAKE cannot be swapped directly into a position token.
    struct AnchorConfig {
        bool active;
        uint256 anchorTokenMinBalance;
    }

    /// @notice Parameters for CAKE reward compounding before range or fee compounding.
    struct RewardCompoundParams {
        uint256 minCakeReward;
        uint256 cakeSplitBps;
        IUniswapV3Pool token0CakePool;
        IUniswapV3Pool token0AnchorPool;
        IUniswapV3Pool token1CakePool;
        IUniswapV3Pool token1AnchorPool;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct RewardSwapValidation {
        address poolToken0;
        address poolToken1;
        bool swap0For1;
        uint160 sqrtPriceX96;
        uint256 amountOutMin;
        uint256 spotAmountOut;
    }

    struct RewardCompoundState {
        address token0;
        address token1;
        uint24 fee;
        uint256 balance0Before;
        uint256 balance1Before;
        uint256 cakeBalanceBefore;
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint256 rewardAmount0;
        uint256 rewardAmount1;
        uint128 liquidityAdded;
    }

    /**
     * @notice Adjust a Pancake-staked token through a configured MasterChef staker.
     */
    function executeWithPancakeStaker(ExecuteParams calldata params, address staker) external {
        if (!operators[msg.sender] || !pancakeStakers[staker]) {
            revert Unauthorized();
        }
        IPancakeMasterChefV3Staker(staker)
            .transform(params.tokenId, address(this), abi.encodeCall(AutoRange.execute, (params)));
    }

    /**
     * @notice Compounds harvested CAKE into the current position before changing range through a staker.
     */
    function executeWithRewardPancakeStaker(
        ExecuteParams calldata params,
        address staker,
        RewardCompoundParams calldata rewardParams
    ) external {
        _executeWithPancakeStakerAndRewardCompound(params, staker, rewardParams);
    }

    /**
     * @notice Explicit alias for reward-compounding before a Pancake staker range change.
     */
    function executeWithPancakeStakerAndRewardCompound(
        ExecuteParams calldata params,
        address staker,
        RewardCompoundParams calldata rewardParams
    ) external {
        _executeWithPancakeStakerAndRewardCompound(params, staker, rewardParams);
    }

    function _executeWithPancakeStakerAndRewardCompound(
        ExecuteParams calldata params,
        address staker,
        RewardCompoundParams calldata rewardParams
    ) internal {
        if (!operators[msg.sender] || !pancakeStakers[staker]) {
            revert Unauthorized();
        }
        IPancakeMasterChefV3Staker(staker)
            .transformWithRewardCompound(
                params.tokenId,
                address(this),
                abi.encode(RewardAction.RANGE, params, _adjustRewardParams(params.tokenId, rewardParams))
            );
    }

    /**
     * @notice Adjust token directly (must be in correct state)
     * Can only be called only from configured operator account, or a Pancake staker via transform.
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function execute(ExecuteParams calldata params) external nonReentrant {
        _execute(params, false);
    }

    function _execute(ExecuteParams memory params, bool alreadyValidated) internal {
        if (!alreadyValidated && msg.sender != address(this) && !operators[msg.sender]) {
            if (pancakeStakers[msg.sender]) {
                _validateCaller(nonfungiblePositionManager, params.tokenId);
            } else {
                revert Unauthorized();
            }
        }

        PositionConfig memory config = positionConfigs[params.tokenId];

        if (config.lowerTickDelta == config.upperTickDelta) {
            revert NotConfigured();
        }

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        ExecuteState memory state;

        // get position info
        (,, state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity,,,,) =
            nonfungiblePositionManager.positions(params.tokenId);

        (state.amount0, state.amount1, state.feeAmount0, state.feeAmount1) = _decreaseFullLiquidityAndCollect(
            params.tokenId, state.liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline
        );

        // if only fees reward is removed before adding
        if (config.onlyFees) {
            state.protocolReward0 = state.feeAmount0 * params.rewardX64 / Q64;
            state.protocolReward1 = state.feeAmount1 * params.rewardX64 / Q64;
            state.amount0 -= state.protocolReward0;
            state.amount1 -= state.protocolReward1;
        }

        if (params.amountIn > (params.swap0To1 ? state.amount0 : state.amount1)) {
            revert SwapAmountTooLarge();
        }

        // get pool info
        state.pool = _getPool(state.token0, state.token1, state.fee);
        (state.sqrtPriceX96, state.currentTick) = _getPoolSlot0(state.pool);

        if (
            state.currentTick < state.tickLower - config.lowerTickLimit
                || state.currentTick >= state.tickUpper + config.upperTickLimit
        ) {
            // check TWAP deviation (this is done for swap and non-swap operations)
            // operation is only allowed when price is close to TWAP price to prevent sandwich attacks
            state.amountOutMin = _validateSwap(
                params.swap0To1,
                params.amountIn,
                state.pool,
                state.currentTick,
                state.sqrtPriceX96,
                TWAPSeconds,
                maxTWAPTickDifference,
                params.swap0To1 ? config.token0SlippageX64 : config.token1SlippageX64
            );

            if (params.amountIn != 0) {
                (state.amountInDelta, state.amountOutDelta) = _routerSwap(
                    Swapper.RouterSwapParams(
                        params.swap0To1 ? IERC20(state.token0) : IERC20(state.token1),
                        params.swap0To1 ? IERC20(state.token1) : IERC20(state.token0),
                        params.amountIn,
                        state.amountOutMin,
                        params.swapData
                    )
                );

                state.amount0 =
                    params.swap0To1 ? state.amount0 - state.amountInDelta : state.amount0 + state.amountOutDelta;
                state.amount1 =
                    params.swap0To1 ? state.amount1 + state.amountOutDelta : state.amount1 - state.amountInDelta;

                // update tick
                (state.sqrtPriceX96, state.currentTick) = _getPoolSlot0(state.pool);
            }

            int24 tickSpacing = _getTickSpacing(state.fee);
            int24 baseTick = state.currentTick - (((state.currentTick % tickSpacing) + tickSpacing) % tickSpacing);

            if (
                baseTick + config.lowerTickDelta == state.tickLower
                    && baseTick + config.upperTickDelta == state.tickUpper
            ) {
                revert SameRange();
            }

            // max amount to add - removing max potential fees (if config.onlyFees - the have been removed already)
            state.maxAddAmount0 = config.onlyFees ? state.amount0 : state.amount0 * Q64 / (params.rewardX64 + Q64);
            state.maxAddAmount1 = config.onlyFees ? state.amount1 : state.amount1 * Q64 / (params.rewardX64 + Q64);

            INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams(
                address(state.token0),
                address(state.token1),
                state.fee,
                SafeCast.toInt24(baseTick + config.lowerTickDelta), // reverts if out of valid range
                SafeCast.toInt24(baseTick + config.upperTickDelta), // reverts if out of valid range
                state.maxAddAmount0,
                state.maxAddAmount1,
                params.amountAddMin0,
                params.amountAddMin1,
                address(this), // is sent to real recipient aftwards
                params.deadline
            );

            // approve npm
            SafeERC20.safeIncreaseAllowance(
                IERC20(state.token0), address(nonfungiblePositionManager), state.maxAddAmount0
            );
            SafeERC20.safeIncreaseAllowance(
                IERC20(state.token1), address(nonfungiblePositionManager), state.maxAddAmount1
            );

            // mint is done to address(this) first - its not a safemint
            (state.newTokenId,, state.amountAdded0, state.amountAdded1) = nonfungiblePositionManager.mint(mintParams);

            // remove remaining approval
            SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), 0);
            SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), 0);

            state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);

            // get the logical owner if the NFT was transformed through a Pancake staker
            state.realOwner = state.owner;
            if (pancakeStakers[state.owner]) {
                state.realOwner = IPancakeMasterChefV3Staker(state.owner).ownerOf(params.tokenId);
            }

            // send the new NFT to the direct owner or Pancake staker
            nonfungiblePositionManager.safeTransferFrom(address(this), state.owner, state.newTokenId);

            // protocol reward is calculated based on added amount (to incentivize optimal swap done by operator)
            if (!config.onlyFees) {
                state.protocolReward0 = state.amountAdded0 * params.rewardX64 / Q64;
                state.protocolReward1 = state.amountAdded1 * params.rewardX64 / Q64;
                state.amount0 -= state.protocolReward0;
                state.amount1 -= state.protocolReward1;
            }

            // send leftover to real owner
            if (state.amount0 - state.amountAdded0 != 0) {
                _transferToken(state.realOwner, IERC20(state.token0), state.amount0 - state.amountAdded0, true);
            }
            if (state.amount1 - state.amountAdded1 != 0) {
                _transferToken(state.realOwner, IERC20(state.token1), state.amount1 - state.amountAdded1, true);
            }

            // copy token config for new token
            positionConfigs[state.newTokenId] = config;
            _emitPositionConfigured(state.newTokenId, config);

            // delete config for old position
            delete positionConfigs[params.tokenId];
            _emitPositionConfigured(params.tokenId, PositionConfig(0, 0, 0, 0, 0, 0, false, false, 0, 0, 0, 0));

            emit RangeChanged(params.tokenId, state.newTokenId);
        } else {
            revert NotReady();
        }
    }

    /// @notice params for autoCompound()
    struct AutoCompoundParams {
        // tokenid to autocompound
        uint256 tokenId;
        // swap direction - calculated off-chain
        bool swap0To1;
        // swap amount - calculated off-chain - if this is set to 0 no swap happens
        uint256 amountIn;
        // for PancakeSwap v3 operations
        uint256 deadline;
    }

    // state used during autocompound execution
    struct AutoCompoundState {
        address owner;
        address realOwner;
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        uint256 priceX96;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 compounded0;
        uint256 compounded1;
        int24 tick;
        uint160 sqrtPriceX96;
        uint256 amountInDelta;
        uint256 amountOutDelta;
    }

    /**
     * @notice Fee-compound a Pancake-staked token through a configured MasterChef staker.
     */
    function autoCompoundWithPancakeStaker(AutoCompoundParams calldata params, address staker) external {
        if (!operators[msg.sender] || !pancakeStakers[staker]) {
            revert Unauthorized();
        }
        IPancakeMasterChefV3Staker(staker)
            .transform(params.tokenId, address(this), abi.encodeCall(AutoRange.autoCompound, (params)));
    }

    /**
     * @notice Compounds harvested CAKE into the current position before fee-compounding through a staker.
     */
    function autoCompoundWithRewardPancakeStaker(
        AutoCompoundParams calldata params,
        address staker,
        RewardCompoundParams calldata rewardParams
    ) external {
        _autoCompoundWithPancakeStakerAndRewardCompound(params, staker, rewardParams);
    }

    /**
     * @notice Explicit alias for reward-compounding before Pancake staker fee compounding.
     */
    function autoCompoundWithPancakeStakerAndRewardCompound(
        AutoCompoundParams calldata params,
        address staker,
        RewardCompoundParams calldata rewardParams
    ) external {
        _autoCompoundWithPancakeStakerAndRewardCompound(params, staker, rewardParams);
    }

    function _autoCompoundWithPancakeStakerAndRewardCompound(
        AutoCompoundParams calldata params,
        address staker,
        RewardCompoundParams calldata rewardParams
    ) internal {
        if (!operators[msg.sender] || !pancakeStakers[staker]) {
            revert Unauthorized();
        }
        IPancakeMasterChefV3Staker(staker)
            .transformWithRewardCompound(
                params.tokenId,
                address(this),
                abi.encode(RewardAction.AUTO_COMPOUND, params, _adjustRewardParams(params.tokenId, rewardParams))
            );
    }

    /**
     * @notice Autocompound position directly (must be in correct state)
     * Can only be called only from configured operator account, or a Pancake staker via transform.
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function autoCompound(AutoCompoundParams calldata params) external nonReentrant {
        _autoCompound(params, false);
    }

    function _autoCompound(AutoCompoundParams memory params, bool alreadyValidated) internal {
        if (!alreadyValidated && msg.sender != address(this) && !operators[msg.sender]) {
            if (pancakeStakers[msg.sender]) {
                _validateCaller(nonfungiblePositionManager, params.tokenId);
            } else {
                revert Unauthorized();
            }
        }

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (!config.autoCompound) {
            revert NotConfigured();
        }
        if (totalRewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        AutoCompoundState memory state;

        // collect fees - if the position doesn't approve this contract or is not called from a staker transform, it won't work
        (state.amount0, state.amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                params.tokenId, address(this), type(uint128).max, type(uint128).max
            )
        );

        if (state.amount0 < uint256(config.autoCompoundMin0) || state.amount1 < uint256(config.autoCompoundMin1)) {
            revert NotEnoughReward();
        }

        // get position info
        (,, state.token0, state.token1, state.fee, state.tickLower, state.tickUpper,,,,,) =
            nonfungiblePositionManager.positions(params.tokenId);

        // only if there are balances to work with - start autocompounding process
        if (state.amount0 != 0 || state.amount1 != 0) {
            uint256 amountIn = params.amountIn;

            // if a swap is requested - check TWAP oracle
            if (amountIn != 0) {
                if (amountIn > (params.swap0To1 ? state.amount0 : state.amount1)) {
                    revert SwapAmountTooLarge();
                }

                IUniswapV3Pool pool = _getPool(state.token0, state.token1, state.fee);
                (state.sqrtPriceX96, state.tick) = _getPoolSlot0(pool);

                // how many seconds are needed for TWAP protection
                uint256 amountOutMin = _validateSwap(
                    params.swap0To1,
                    amountIn,
                    pool,
                    state.tick,
                    state.sqrtPriceX96,
                    TWAPSeconds,
                    maxTWAPTickDifference,
                    params.swap0To1 ? config.token0SlippageX64 : config.token1SlippageX64
                );

                (state.amountInDelta, state.amountOutDelta) = _poolSwap(
                    Swapper.PoolSwapParams(
                        pool,
                        IERC20(state.token0),
                        IERC20(state.token1),
                        state.fee,
                        params.swap0To1,
                        amountIn,
                        amountOutMin
                    )
                );
                state.amount0 =
                    params.swap0To1 ? state.amount0 - state.amountInDelta : state.amount0 + state.amountOutDelta;
                state.amount1 =
                    params.swap0To1 ? state.amount1 + state.amountOutDelta : state.amount1 - state.amountInDelta;
            }

            uint256 rewardX64 = totalRewardX64;

            state.maxAddAmount0 = state.amount0 * Q64 / (rewardX64 + Q64);
            state.maxAddAmount1 = state.amount1 * Q64 / (rewardX64 + Q64);

            // deposit liquidity into tokenId
            if (state.maxAddAmount0 != 0 || state.maxAddAmount1 != 0) {
                // approve npm
                SafeERC20.safeIncreaseAllowance(
                    IERC20(state.token0), address(nonfungiblePositionManager), state.maxAddAmount0
                );
                SafeERC20.safeIncreaseAllowance(
                    IERC20(state.token1), address(nonfungiblePositionManager), state.maxAddAmount1
                );

                (, state.compounded0, state.compounded1) = nonfungiblePositionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams(
                        params.tokenId, state.maxAddAmount0, state.maxAddAmount1, 0, 0, params.deadline
                    )
                );

                // remove remaining approval
                SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), 0);
                SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), 0);

                // fees are always calculated based on added amount (to incentivize optimal swap)
                state.amount0Fees = state.compounded0 * rewardX64 / Q64;
                state.amount1Fees = state.compounded1 * rewardX64 / Q64;
            }

            state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);

            // get the logical owner if the NFT was transformed through a Pancake staker
            state.realOwner = state.owner;
            if (pancakeStakers[state.owner]) {
                state.realOwner = IPancakeMasterChefV3Staker(state.owner).ownerOf(params.tokenId);
            }

            // return remaining tokens for owner
            state.amount0 = state.amount0 - state.compounded0 - state.amount0Fees;
            if (state.amount0 > 0) {
                _transferToken(state.realOwner, IERC20(state.token0), state.amount0, true);
            }
            state.amount1 = state.amount1 - state.compounded1 - state.amount1Fees;
            if (state.amount1 > 0) {
                _transferToken(state.realOwner, IERC20(state.token1), state.amount1, true);
            }
        }

        emit AutoCompounded(
            params.tokenId,
            state.compounded0,
            state.compounded1,
            state.amount0Fees,
            state.amount1Fees,
            state.token0,
            state.token1
        );
    }

    // function to configure an owner-held token to be used with this runner
    // it needs to have approvals set for this contract beforehand
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        _configToken(tokenId, address(0), config);
    }

    // function to configure a token held by a configured Pancake staker
    function configToken(uint256 tokenId, address staker, PositionConfig calldata config) external {
        _configToken(tokenId, staker, config);
    }

    function _configToken(uint256 tokenId, address staker, PositionConfig calldata config) internal {
        _validateOwner(nonfungiblePositionManager, tokenId, staker);

        // lower tick must be always below or equal to upper tick - if they are equal - range adjustment is deactivated
        if (config.lowerTickDelta > config.upperTickDelta || config.maxRewardX64 > MAX_REWARD_X64) {
            revert InvalidConfig();
        }

        positionConfigs[tokenId] = config;
        _emitPositionConfigured(tokenId, config);
    }

    function _emitPositionConfigured(uint256 tokenId, PositionConfig memory config) internal {
        emit PositionConfigured(
            tokenId,
            config.lowerTickLimit,
            config.upperTickLimit,
            config.lowerTickDelta,
            config.upperTickDelta,
            config.token0SlippageX64,
            config.token1SlippageX64,
            config.onlyFees,
            config.autoCompound,
            config.maxRewardX64,
            config.autoCompoundMin0,
            config.autoCompoundMin1,
            config.autoCompoundRewardMin
        );
    }

    /**
     * @notice Management method to lower autocompound reward(onlyOwner)
     * @param _totalRewardX64 new total reward (can't be higher than current total reward)
     */
    function setAutoCompoundReward(uint64 _totalRewardX64) external onlyOwner {
        if (_totalRewardX64 > totalRewardX64) {
            revert InvalidConfig();
        }
        totalRewardX64 = _totalRewardX64;
        emit AutoCompoundRewardUpdated(msg.sender, _totalRewardX64);
    }

    /// @notice Sets CAKE token used by Pancake reward-compound wrappers.
    function setCakeToken(IERC20 _cakeToken) external onlyOwner {
        if (address(_cakeToken) == address(0)) {
            revert InvalidConfig();
        }
        cakeToken = _cakeToken;
        emit CakeTokenSet(address(_cakeToken));
    }

    /// @notice Adds, updates, or removes an anchor token accepted for dynamic CAKE reward routes.
    function setRewardAnchor(address anchorToken, uint256 anchorTokenMinBalance) external onlyOwner {
        if (anchorToken == address(0) || anchorToken == address(cakeToken)) {
            revert InvalidConfig();
        }

        if (anchorTokenMinBalance == 0) {
            delete rewardAnchors[anchorToken];
            emit RewardAnchorSet(anchorToken, 0, false);
            return;
        }

        rewardAnchors[anchorToken] = AnchorConfig({active: true, anchorTokenMinBalance: anchorTokenMinBalance});
        emit RewardAnchorSet(anchorToken, anchorTokenMinBalance, true);
    }

    /// @notice Callback used by Pancake staker reward-compound transforms.
    function executeWithReward(uint256 tokenId, address owner, uint256 cakeAmount, bytes calldata data)
        external
        override
        nonReentrant
    {
        if (!pancakeStakers[msg.sender]) {
            revert Unauthorized();
        }
        _validateCaller(nonfungiblePositionManager, tokenId);
        if (owner == address(0)) {
            revert InvalidConfig();
        }

        RewardAction action = abi.decode(data, (RewardAction));
        if (action == RewardAction.RANGE) {
            (, ExecuteParams memory params, RewardCompoundParams memory rewardParams) =
                abi.decode(data, (RewardAction, ExecuteParams, RewardCompoundParams));
            if (params.tokenId != tokenId) {
                revert InvalidConfig();
            }
            _compoundCakeRewardIntoPosition(tokenId, owner, cakeAmount, rewardParams, params.deadline);
            _execute(params, true);
            return;
        }
        if (action == RewardAction.AUTO_COMPOUND) {
            (, AutoCompoundParams memory params, RewardCompoundParams memory rewardParams) =
                abi.decode(data, (RewardAction, AutoCompoundParams, RewardCompoundParams));
            if (params.tokenId != tokenId) {
                revert InvalidConfig();
            }
            _compoundCakeRewardIntoPosition(tokenId, owner, cakeAmount, rewardParams, params.deadline);
            _autoCompound(params, true);
            return;
        }

        revert InvalidConfig();
    }

    function _adjustRewardParams(uint256 tokenId, RewardCompoundParams calldata rewardParams)
        internal
        view
        returns (RewardCompoundParams memory adjusted)
    {
        adjusted = rewardParams;
        uint256 configuredMinReward = uint256(positionConfigs[tokenId].autoCompoundRewardMin);
        if (configuredMinReward > adjusted.minCakeReward) {
            adjusted.minCakeReward = configuredMinReward;
        }
    }

    function _compoundCakeRewardIntoPosition(
        uint256 tokenId,
        address owner,
        uint256 cakeAmount,
        RewardCompoundParams memory rewardParams,
        uint256 deadline
    ) internal {
        if (rewardParams.cakeSplitBps > 10_000) {
            revert InvalidConfig();
        }
        if (cakeAmount < rewardParams.minCakeReward) {
            revert NotEnoughReward();
        }
        if (cakeAmount == 0) {
            return;
        }
        if (address(cakeToken) == address(0)) {
            revert NotConfigured();
        }
        if (totalRewardX64 > positionConfigs[tokenId].maxRewardX64) {
            revert ExceedsMaxReward();
        }

        RewardCompoundState memory state;
        (,, state.token0, state.token1, state.fee,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        IUniswapV3Pool positionPool = _getPool(state.token0, state.token1, state.fee);
        if (address(positionPool) == address(0)) {
            revert InvalidPool();
        }

        state.balance0Before = IERC20(state.token0).balanceOf(address(this));
        state.balance1Before = IERC20(state.token1).balanceOf(address(this));
        state.cakeBalanceBefore = cakeToken.balanceOf(address(this));
        if (state.cakeBalanceBefore < cakeAmount) {
            revert InsufficientLiquidity();
        }
        state.cakeBalanceBefore -= cakeAmount;
        if (state.token0 == address(cakeToken)) {
            state.balance0Before -= cakeAmount;
        }
        if (state.token1 == address(cakeToken)) {
            state.balance1Before -= cakeAmount;
        }

        uint256 requestedCake0 = cakeAmount * rewardParams.cakeSplitBps / 10_000;
        uint256 requestedCake1 = cakeAmount - requestedCake0;
        (, state.amount0) =
            _swapCakeToTarget(state.token0, rewardParams.token0CakePool, rewardParams.token0AnchorPool, requestedCake0);
        (, state.amount1) =
            _swapCakeToTarget(state.token1, rewardParams.token1CakePool, rewardParams.token1AnchorPool, requestedCake1);

        uint256 rewardX64 = totalRewardX64;
        state.maxAddAmount0 = state.amount0 * Q64 / (rewardX64 + Q64);
        state.maxAddAmount1 = state.amount1 * Q64 / (rewardX64 + Q64);

        if (state.maxAddAmount0 != 0) {
            IERC20(state.token0).safeIncreaseAllowance(address(nonfungiblePositionManager), state.maxAddAmount0);
        }
        if (state.maxAddAmount1 != 0) {
            IERC20(state.token1).safeIncreaseAllowance(address(nonfungiblePositionManager), state.maxAddAmount1);
        }

        if (state.maxAddAmount0 != 0 || state.maxAddAmount1 != 0) {
            (state.liquidityAdded, state.amountAdded0, state.amountAdded1) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId,
                    state.maxAddAmount0,
                    state.maxAddAmount1,
                    rewardParams.amount0Min,
                    rewardParams.amount1Min,
                    deadline
                )
            );
            if (state.liquidityAdded == 0 && (state.amountAdded0 != 0 || state.amountAdded1 != 0)) {
                revert InvalidConfig();
            }
        }

        if (state.maxAddAmount0 != 0) {
            IERC20(state.token0).safeApprove(address(nonfungiblePositionManager), 0);
        }
        if (state.maxAddAmount1 != 0) {
            IERC20(state.token1).safeApprove(address(nonfungiblePositionManager), 0);
        }

        state.rewardAmount0 = state.amountAdded0 * rewardX64 / Q64;
        state.rewardAmount1 = state.amountAdded1 * rewardX64 / Q64;
        _sendExcessBalance(tokenId, state.token0, owner, state.balance0Before + state.rewardAmount0);
        if (state.token1 != state.token0) {
            _sendExcessBalance(tokenId, state.token1, owner, state.balance1Before + state.rewardAmount1);
        }
        if (address(cakeToken) != state.token0 && address(cakeToken) != state.token1) {
            _sendExcessBalance(tokenId, address(cakeToken), owner, state.cakeBalanceBefore);
        }
    }

    function _validateCakeAnchorPool(address anchorToken, IUniswapV3Pool cakePool, AnchorConfig memory anchor)
        internal
        view
    {
        if (address(cakePool) == address(0)) {
            revert NotConfigured();
        }

        address poolToken0 = cakePool.token0();
        address poolToken1 = cakePool.token1();
        if (!(poolToken0 == address(cakeToken) && poolToken1 == anchorToken || poolToken0 == anchorToken
                    && poolToken1 == address(cakeToken))) {
            revert InvalidPool();
        }
        _validateCanonicalPool(cakePool, poolToken0, poolToken1);
        if (IERC20(anchorToken).balanceOf(address(cakePool)) < anchor.anchorTokenMinBalance) {
            revert InsufficientLiquidity();
        }
    }

    function _validateTargetAnchorPool(address targetToken, IUniswapV3Pool targetAnchorPool)
        internal
        view
        returns (address anchorToken, AnchorConfig memory anchor)
    {
        if (address(targetAnchorPool) == address(0)) {
            revert NotConfigured();
        }

        address poolToken0 = targetAnchorPool.token0();
        address poolToken1 = targetAnchorPool.token1();
        if (poolToken0 == targetToken) {
            anchorToken = poolToken1;
        } else if (poolToken1 == targetToken) {
            anchorToken = poolToken0;
        } else {
            revert InvalidPool();
        }

        anchor = rewardAnchors[anchorToken];
        if (!anchor.active) {
            revert NotConfigured();
        }

        _validateCanonicalPool(targetAnchorPool, poolToken0, poolToken1);
    }

    function _validateCanonicalPool(IUniswapV3Pool pool, address token0, address token1) internal view {
        if (address(pool) == address(0) || address(_getPool(token0, token1, pool.fee())) != address(pool)) {
            revert InvalidPool();
        }
    }

    function _swapCakeToTarget(
        address targetToken,
        IUniswapV3Pool cakeAnchorPool,
        IUniswapV3Pool targetAnchorPool,
        uint256 amountIn
    ) internal returns (uint256 spentCake, uint256 amountOut) {
        if (amountIn == 0) {
            return (0, 0);
        }
        if (targetToken == address(cakeToken)) {
            return (amountIn, amountIn);
        }

        AnchorConfig memory directAnchor = rewardAnchors[targetToken];
        if (directAnchor.active) {
            _validateCakeAnchorPool(targetToken, cakeAnchorPool, directAnchor);
            RewardSwapValidation memory directValidation =
                _validateRewardSwap(cakeAnchorPool, address(cakeToken), targetToken, amountIn);
            amountOut =
                _swapThroughValidatedPool(cakeAnchorPool, directValidation, amountIn, directValidation.amountOutMin);
            return (amountIn, amountOut);
        }

        (address anchorToken, AnchorConfig memory anchor) = _validateTargetAnchorPool(targetToken, targetAnchorPool);
        _validateCakeAnchorPool(anchorToken, cakeAnchorPool, anchor);
        RewardSwapValidation memory intermediateValidation =
            _validateRewardSwap(cakeAnchorPool, address(cakeToken), anchorToken, amountIn);
        uint256 intermediateAmount = _swapThroughValidatedPool(
            cakeAnchorPool, intermediateValidation, amountIn, intermediateValidation.amountOutMin
        );

        RewardSwapValidation memory targetValidation =
            _validateRewardSwap(targetAnchorPool, anchorToken, targetToken, intermediateAmount);
        uint256 routeAmountOutMin = _combinedRouteAmountOutMin(intermediateValidation, targetValidation);
        uint256 targetAmountOutMin =
            targetValidation.amountOutMin > routeAmountOutMin ? targetValidation.amountOutMin : routeAmountOutMin;

        amountOut =
            _swapThroughValidatedPool(targetAnchorPool, targetValidation, intermediateAmount, targetAmountOutMin);
        return (amountIn, amountOut);
    }

    function _swapThroughValidatedPool(
        IUniswapV3Pool pool,
        RewardSwapValidation memory validation,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) {
            return 0;
        }

        (, amountOut) = _poolSwap(
            PoolSwapParams({
                pool: pool,
                token0: IERC20(validation.poolToken0),
                token1: IERC20(validation.poolToken1),
                fee: pool.fee(),
                swap0For1: validation.swap0For1,
                amountIn: amountIn,
                amountOutMin: amountOutMin
            })
        );
    }

    function _validateRewardSwap(IUniswapV3Pool pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (RewardSwapValidation memory validation)
    {
        if (address(pool) == address(0)) {
            revert NotConfigured();
        }

        validation.poolToken0 = pool.token0();
        validation.poolToken1 = pool.token1();
        _validateCanonicalPool(pool, validation.poolToken0, validation.poolToken1);

        if (validation.poolToken0 == tokenIn && validation.poolToken1 == tokenOut) {
            validation.swap0For1 = true;
        } else if (validation.poolToken0 == tokenOut && validation.poolToken1 == tokenIn) {
            validation.swap0For1 = false;
        } else {
            revert InvalidPool();
        }

        int24 currentTick;
        (validation.sqrtPriceX96, currentTick) = _getPoolSlot0(pool);
        validation.spotAmountOut = _quoteRewardSwapAmountOut(validation.swap0For1, amountIn, validation.sqrtPriceX96);
        validation.amountOutMin = _validateSwap(
            validation.swap0For1,
            amountIn,
            pool,
            currentTick,
            validation.sqrtPriceX96,
            TWAPSeconds,
            maxTWAPTickDifference,
            REWARD_MAX_PRICE_DIFFERENCE_X64
        );
    }

    function _combinedRouteAmountOutMin(
        RewardSwapValidation memory intermediateValidation,
        RewardSwapValidation memory targetValidation
    ) internal pure returns (uint256 amountOutMin) {
        uint256 routeSpotAmountOut = _quoteRewardSwapAmountOut(
            targetValidation.swap0For1, intermediateValidation.spotAmountOut, targetValidation.sqrtPriceX96
        );
        amountOutMin = FullMath.mulDiv(routeSpotAmountOut, Q64 - REWARD_MAX_PRICE_DIFFERENCE_X64, Q64);
    }

    function _quoteRewardSwapAmountOut(bool swap0For1, uint256 amountIn, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) {
            return 0;
        }

        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (swap0For1) {
            return FullMath.mulDiv(amountIn, priceX96, Q96);
        }
        return FullMath.mulDiv(amountIn, Q96, priceX96);
    }

    function _sendExcessBalance(uint256 tokenId, address token, address owner, uint256 protectedBalance) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < protectedBalance) {
            revert InsufficientLiquidity();
        }

        uint256 amount = balance - protectedBalance;
        if (amount != 0) {
            IERC20(token).safeTransfer(owner, amount);
            emit LeftoverSent(tokenId, token, owner, amount);
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
            int24 spacing = IUniswapV3Factory(factory).feeAmountTickSpacing(fee);
            if (spacing <= 0) {
                revert NotSupportedFeeTier();
            }
            return spacing;
        }
    }
}
