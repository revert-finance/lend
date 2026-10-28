// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "../automators/Automator.sol";
import "../transformers/Transformer.sol";
import "../interfaces/IGaugeManager.sol";
import "../utils/VaultLib.sol";

/// @title AutoRangeAndCompound
/// @notice Allows operator of AutoRangeAndCompound contract (Revert controlled bot) to change range for configured positions
/// And optionally to autocompound position (depending on configuration)
/// Positions need to be approved (setApprovalForAll) for the contract and configured with configToken method
/// When executed a new position is created and automatically configured the same way as the original position
/// When position is inside Vault - transform is called
contract AutoRangeAndCompound is Transformer, Automator, ReentrancyGuard {
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

    // config changes
    event AutoCompoundRewardsUpdated(address account, uint64 totalRewardX64, uint64 simpleRewardX64);
    event CompoundModeConfigured(uint256 indexed tokenId, CompoundMode mode);
    event StakingManagementConfigured(
        uint256 indexed tokenId, address indexed vault, address indexed owner, bool managed
    );
    event StakeChangeCooldownUpdated(uint32 cooldownBlocks);

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

    // fee tier of a position for every compound of fees or rewards: Advanced is the default (totalRewardX64, 5%),
    // Simple is the higher tier (simpleRewardX64, 10%). Set with the position config (configToken), kept in
    // compoundModes, copied to the replacement position of a range adjustment.
    enum CompoundMode {
        Advanced,
        Simple
    }

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
        uint128 autoCompoundMin0; // min amount0 to add in autoCompound increaseLiquidity
        uint128 autoCompoundMin1; // min amount1 to add in autoCompound increaseLiquidity
        uint128 autoCompoundRewardMin; // min claimed AERO when pre-compounding staked rewards
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public positionConfigs;
    mapping(uint256 => CompoundMode) public compoundModes; // fee tier per position, see CompoundMode

    // operator-managed staking (compound-only policy): consenting owner per position and vault (zero when not
    // managed). Consent applies only while that address is the vault's current owner of the position: it is
    // suspended while the position is out of the vault or owned by someone else, never carries to another vault,
    // re-applies when the same owner re-deposits the same position into the same vault, and ends on revocation.
    mapping(uint256 => mapping(address => address)) public stakingConsent;
    mapping(uint256 => uint256) public lastStakeChangeBlock;
    uint32 public stakeChangeCooldownBlocks;

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
        uint256 deadline; // for uniswap operations
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
    uint64 public constant MAX_REWARD_X64 = 1_844_674_407_370_955_161; // floor(Q64 / 10)
    uint64 public totalRewardX64 = 922_337_203_685_477_580; // 5% (floor(Q64 / 20)): Advanced mode, the default
    uint64 public simpleRewardX64 = MAX_REWARD_X64; // 10%: Simple mode

    /**
     * @notice Adjust token (which is in a Vault) - via transform method
     * Can only be called from configured operator account - vault must be configured as well
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     * Keeps the current custody; a staked position is not adjusted inside the gauge's early-unstake penalty window
     */
    function executeWithVault(ExecuteParams calldata params, address vault) external {
        _prepareTransform(params.tokenId, vault);
        // Plain transforms can now compound rewards before the callback. Require readiness before those swaps.
        PositionConfig storage config = positionConfigs[params.tokenId];
        VaultLib.requireRangeReady(
            nonfungiblePositionManager, factory, params.tokenId, config.lowerTickLimit, config.upperTickLimit
        );
        IVault(vault).transform(params.tokenId, address(this), abi.encodeCall(AutoRangeAndCompound.execute, (params)));
    }

    /**
     * @notice Adjust token in a vault, compound staked gauge rewards first (if position is currently staked) and end
     * in `rewardParams.stakeTarget` custody. Can only be called from configured operator account - vault must be
     * configured as well. A real custody change needs the owner's staking-management opt-in, respects the cooldown
     * and never unstakes inside the gauge's early-unstake penalty window.
     */
    function executeWithVaultAndRewardCompound(
        ExecuteParams calldata params,
        address vault,
        IVault.RewardCompoundParams calldata rewardParams
    ) external {
        bool changes = _prepareStakeChange(params.tokenId, vault, rewardParams.stakeTarget);
        IVault.RewardCompoundParams memory adjustedRewardParams = rewardParams;
        if (changes) {
            adjustedRewardParams.minAeroReward = 0;
        }
        IVault(vault)
            .transformWithRewardCompound(
                params.tokenId,
                address(this),
                abi.encodeCall(AutoRangeAndCompound.execute, (params)),
                adjustedRewardParams
            );
    }

    /**
     * @notice Adjust token directly (must be in correct state)
     * Can only be called only from configured operator account, or vault via transform
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function execute(ExecuteParams calldata params) external {
        if (!operators[msg.sender]) {
            if (vaults[msg.sender]) {
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

            int24 tickSpacing = IAerodromeSlipstreamPool(address(state.pool)).tickSpacing();
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
            (state.newTokenId,, state.amountAdded0, state.amountAdded1) = _mintPosition(mintParams);

            // remove remaining approval
            SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), 0);
            SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), 0);

            // get the real owner - if owner is vault - for sending leftover tokens
            (state.owner, state.realOwner) = _ownerAndRealOwner(params.tokenId);
            if (vaults[state.owner]) {
                // a vault transform only accepts the replacement position its active transformer announced
                IVault(state.owner).expectReplacement(state.newTokenId);
            }

            // send the new nft to the owner / vault
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
            compoundModes[state.newTokenId] = compoundModes[params.tokenId];
            _emitPositionConfigured(state.newTokenId);

            // delete config for old position
            delete positionConfigs[params.tokenId];
            delete compoundModes[params.tokenId];
            emit PositionConfigured(params.tokenId, 0, 0, 0, 0, 0, 0, false, false, 0, 0, 0, 0);

            // Consent follows the current economic owner only; a previous owner's record must expire.
            if (vaults[msg.sender]) {
                address consentingOwner = stakingConsent[params.tokenId][msg.sender];
                delete stakingConsent[params.tokenId][msg.sender];
                if (consentingOwner != address(0) && consentingOwner == state.realOwner) {
                    stakingConsent[state.newTokenId][msg.sender] = consentingOwner;
                    emit StakingManagementConfigured(state.newTokenId, msg.sender, consentingOwner, true);
                }
            }
            // The old NFT remains reusable, so both token IDs retain the last operator decision.
            lastStakeChangeBlock[state.newTokenId] = lastStakeChangeBlock[params.tokenId];

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
        // for uniswap operations
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
     * @notice Autocompound position (which is in a Vault) - via transform method
     * Can only be called from configured operator account - vault must be configured as well
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     * Keeps the current custody; a staked position is not compounded inside the gauge's early-unstake penalty window
     */
    function autoCompoundWithVault(AutoCompoundParams calldata params, address vault) external {
        _prepareTransform(params.tokenId, vault);
        IVault(vault)
            .transform(params.tokenId, address(this), abi.encodeCall(AutoRangeAndCompound.autoCompound, (params)));
    }

    /**
     * @notice Autocompound position in a vault, compound staked gauge rewards first (if position is currently staked)
     * and end in `rewardParams.stakeTarget` custody. Can only be called from configured operator account - vault must
     * be configured as well. A real custody change needs the owner's staking-management opt-in, respects the cooldown
     * and never unstakes inside the gauge's early-unstake penalty window; it compounds fees before a stake and staked
     * rewards before an unstake (compound-only policy) without the configured minimums, so dust never stalls it.
     */
    function autoCompoundWithVaultAndRewardCompound(
        AutoCompoundParams calldata params,
        address vault,
        IVault.RewardCompoundParams calldata rewardParams
    ) external {
        bool changes = _prepareStakeChange(params.tokenId, vault, rewardParams.stakeTarget);
        IVault.RewardCompoundParams memory adjustedRewardParams = rewardParams;
        adjustedRewardParams.minAeroReward = changes ? 0 : positionConfigs[params.tokenId].autoCompoundRewardMin;
        IVault(vault)
            .transformWithRewardCompound(
                params.tokenId,
                address(this),
                changes
                    ? abi.encodeCall(AutoRangeAndCompound.autoCompoundForStakeChange, (params))
                    : abi.encodeCall(AutoRangeAndCompound.autoCompound, (params)),
                adjustedRewardParams
            );
    }

    /**
     * @notice Autocompound position directly (must be in correct state)
     * Can only be called only from configured operator account, or vault via transform
     * A swap is skipped when the pool price deviates from its TWAP by more than the configured tick difference,
     * and reverts when its output falls below the position's configured per-token slippage limit
     */
    function autoCompound(AutoCompoundParams calldata params) external nonReentrant {
        _autoCompound(params, true);
    }

    /**
     * @notice Autocompound for a staking custody change: same as autoCompound but without the configured
     * autoCompound flag and minimum-fee gate, so a change always compounds whatever fees exist first.
     * Only for positions whose owner opted into operator-managed staking.
     */
    function autoCompoundForStakeChange(AutoCompoundParams calldata params) external nonReentrant {
        // only as the payload of a vault transform, for a position whose current owner opted in
        if (!vaults[msg.sender] || !_isStakingManaged(params.tokenId, msg.sender)) {
            revert Unauthorized();
        }
        _autoCompound(params, false);
    }

    function _autoCompound(AutoCompoundParams calldata params, bool enforceConfig) internal {
        if (!operators[msg.sender]) {
            if (vaults[msg.sender]) {
                _validateCaller(nonfungiblePositionManager, params.tokenId);
            } else {
                revert Unauthorized();
            }
        }

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (enforceConfig && !config.autoCompound) {
            revert NotConfigured();
        }

        AutoCompoundState memory state;

        // collect fees - if the position doesn't have operator set or is called from vault - it won't work
        (state.amount0, state.amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                params.tokenId, address(this), type(uint128).max, type(uint128).max
            )
        );

        // Minimum fee thresholds gate autocompound execution.
        if (enforceConfig && (state.amount0 < config.autoCompoundMin0 || state.amount1 < config.autoCompoundMin1)) {
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
                IUniswapV3Pool pool = _getPool(state.token0, state.token1, state.fee);
                (state.sqrtPriceX96, state.tick) = _getPoolSlot0(pool);

                // how many seconds are needed for TWAP protection
                uint32 tSecs = TWAPSeconds;
                if (tSecs != 0) {
                    if (!_hasMaxTWAPTickDifference(pool, tSecs, state.tick, maxTWAPTickDifference)) {
                        // if there is no valid TWAP - disable swap
                        amountIn = 0;
                    }
                }
                // if still needed - do swap
                if (amountIn != 0) {
                    // The TWAP check above only bounds the pre-swap price; the execution itself must stay within the
                    // owner's configured per-token price tolerance, otherwise the swap reverts (SlippageError).
                    uint256 amountOutMin = _calculateAmountOutMin(
                        params.swap0To1,
                        amountIn,
                        state.sqrtPriceX96,
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
            }

            uint256 rewardX64 = compoundRewardX64(params.tokenId);

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

            // get the real owner - if owner is vault - for sending leftover tokens
            (state.owner, state.realOwner) = _ownerAndRealOwner(params.tokenId);

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

    /**
     * @notice Owner opt-in: lets the operator move this vault position between staked and unstaked custody.
     * Changes always compound fees before staking and staked rewards before unstaking (compound-only policy).
     */
    function configStakingManagement(uint256 tokenId, address vault, bool managed) external {
        if (vault == address(0)) {
            revert Unauthorized();
        }
        _validateOwner(nonfungiblePositionManager, tokenId, vault);
        stakingConsent[tokenId][vault] = managed ? msg.sender : address(0);
        emit StakingManagementConfigured(tokenId, vault, msg.sender, managed);
    }

    // consent applies only while the consenting owner currently owns the position in that vault
    function _isStakingManaged(uint256 tokenId, address vault) internal returns (bool) {
        address consentingOwner = stakingConsent[tokenId][vault];
        return consentingOwner != address(0) && consentingOwner == IVault(vault).ownerOf(tokenId);
    }

    /// @notice Owner controlled function to set the minimum blocks between two operator stake changes of a position
    function setStakeChangeCooldown(uint32 cooldownBlocks) external onlyOwner {
        stakeChangeCooldownBlocks = cooldownBlocks;
        emit StakeChangeCooldownUpdated(cooldownBlocks);
    }

    /// @notice Called only by a registered vault while it accepts an authenticated replacement NFT.
    function migrateStakingPolicy(uint256 oldTokenId, uint256 newTokenId) external {
        if (!vaults[msg.sender] || IVault(msg.sender).transformedTokenId() != oldTokenId) revert Unauthorized();
        lastStakeChangeBlock[newTokenId] = lastStakeChangeBlock[oldTokenId];
    }

    // owner of the position and the real owner: the vault's owner of the position when a vault holds it
    function _ownerAndRealOwner(uint256 tokenId) internal returns (address owner, address realOwner) {
        owner = nonfungiblePositionManager.ownerOf(tokenId);
        realOwner = vaults[owner] ? IVault(owner).ownerOf(tokenId) : owner;
    }

    // operator/vault auth for the plain transform wrappers; they keep the current custody, so the only staking rule
    // that applies to them is the gauge penalty window
    function _prepareTransform(uint256 tokenId, address vault) internal view {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        (address gaugeManager, bool staked) = _stakeState(tokenId, vault);
        if (staked) {
            _requireOutsidePenaltyWindow(gaugeManager, tokenId);
        }
    }

    // operator/vault auth; for a real custody change also owner opt-in, cooldown and gauge penalty window
    function _prepareStakeChange(uint256 tokenId, address vault, IVault.StakeTarget target)
        internal
        returns (bool changes)
    {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        if (target == IVault.StakeTarget.Keep) {
            return false;
        }
        (address gaugeManager, bool staked) = _stakeState(tokenId, vault);
        changes = staked != (target == IVault.StakeTarget.Staked);
        if (!changes) {
            return false;
        }
        if (!_isStakingManaged(tokenId, vault)) {
            revert Unauthorized();
        }
        uint256 lastChange = lastStakeChangeBlock[tokenId];
        if (lastChange != 0 && block.number < lastChange + stakeChangeCooldownBlocks) {
            revert NotReady();
        }
        if (staked) {
            _requireOutsidePenaltyWindow(gaugeManager, tokenId);
        }
        lastStakeChangeBlock[tokenId] = block.number;
    }

    // the vault's gauge manager and whether it currently stakes the position (never for a vault without one)
    function _stakeState(uint256 tokenId, address vault) internal view returns (address gaugeManager, bool staked) {
        gaugeManager = IVault(vault).gaugeManager();
        staked = gaugeManager != address(0) && IGaugeManager(gaugeManager).tokenIdToGauge(tokenId) != address(0);
    }

    // Every vault transform of a staked position unstakes and restakes it. Inside the gauge's early-unstake penalty
    // window the unstake claims the accrued rewards at the penalized rate and the restake restarts the window, so the
    // operator never transforms a staked position before penaltyWindowEnd (Cantina LEND-4). Only for staked positions.
    function _requireOutsidePenaltyWindow(address gaugeManager, uint256 tokenId) internal view {
        if (block.number < IGaugeManager(gaugeManager).penaltyWindowEnd(tokenId)) {
            revert NotReady();
        }
    }

    // function to configure a token to be used with this runner
    // it needs to have approvals set for this contract beforehand
    function configToken(uint256 tokenId, address vault, PositionConfig calldata config, CompoundMode mode) external {
        _validateOwner(nonfungiblePositionManager, tokenId, vault);

        // lower tick must be always below or equal to upper tick - if they are equal - range adjustment is deactivated
        if (config.lowerTickDelta > config.upperTickDelta) {
            revert InvalidConfig();
        }

        positionConfigs[tokenId] = config;
        compoundModes[tokenId] = mode;

        emit CompoundModeConfigured(tokenId, mode);
        _emitPositionConfigured(tokenId);
    }

    function _emitPositionConfigured(uint256 tokenId) internal {
        PositionConfig storage config = positionConfigs[tokenId];
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
     * @notice Reward rate applied to every compound of this position (fee auto-compound here, AERO rewards in
     * GaugeManager): simpleRewardX64 for Simple mode, totalRewardX64 for Advanced mode (the default).
     */
    function compoundRewardX64(uint256 tokenId) public view returns (uint64) {
        return compoundModes[tokenId] == CompoundMode.Simple ? simpleRewardX64 : totalRewardX64;
    }

    /**
     * @notice Management method to lower the auto-compound rewards (neither can be higher than its current value)
     * @param _totalRewardX64 new reward of Advanced mode compounds
     * @param _simpleRewardX64 new reward of Simple mode compounds
     */
    function setAutoCompoundRewards(uint64 _totalRewardX64, uint64 _simpleRewardX64) external onlyOwner {
        if (_totalRewardX64 > totalRewardX64 || _simpleRewardX64 > simpleRewardX64) {
            revert InvalidConfig();
        }
        totalRewardX64 = _totalRewardX64;
        simpleRewardX64 = _simpleRewardX64;
        emit AutoCompoundRewardsUpdated(msg.sender, _totalRewardX64, _simpleRewardX64);
    }
}
