// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../automators/Automator.sol";
import "../transformers/Transformer.sol";
import "../interfaces/IVault.sol";

/// @title AutoExitTransformer
/// @notice Automatically exits vault-collateralized positions when trigger conditions are met.
/// Repays outstanding debt before returning remaining assets to the position owner.
/// Supports both tick-based triggers (stop-loss/take-profit) and debt ratio triggers.
contract AutoExitTransformer is Transformer, Automator, ReentrancyGuard {
    /// @notice Status returned by canExecute indicating why a position can or cannot be executed
    enum ExecuteStatus {
        NOT_CONFIGURED,
        NO_LIQUIDITY,
        TOKEN0_TICK_TRIGGER,
        TOKEN1_TICK_TRIGGER,
        DEBT_RATIO_TRIGGER,
        NOT_READY
    }
    event AutoExitExecuted(
        uint256 indexed tokenId,
        address indexed vault,
        address indexed owner,
        uint256 debtRepaid,
        uint256 amount0Returned,
        uint256 amount1Returned,
        address token0,
        address token1
    );

    event PositionConfigured(
        uint256 indexed tokenId,
        address indexed vault,
        bool isActive,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        uint32 maxDebtRatioX32,
        uint64 maxSlippageX64,
        bool onlyFees,
        uint64 maxRewardX64
    );

    /// @notice Configuration for auto-exit behavior per position
    struct PositionConfig {
        bool isActive;
        // Tick-based triggers (stop-loss / take-profit)
        int24 token0TriggerTick; // Exit when tick < this value
        int24 token1TriggerTick; // Exit when tick >= this value
        // Debt ratio trigger (0 = disabled)
        uint32 maxDebtRatioX32; // Exit when debt/collateral > this (Q32 format, e.g., 0.9 = 0.9 * Q32)
        // Swap slippage protection (max allowed slippage from oracle price)
        uint64 maxSlippageX64; // e.g., 1% = Q64 / 100
        // Reward config
        bool onlyFees; // If true, reward only from fees (not principal)
        uint64 maxRewardX64; // Max reward percentage for operator
    }

    /// @notice Parameters for execute function
    struct ExecuteParams {
        uint256 tokenId;
        address vault;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        // Swap parameters for token0 -> asset (operator specifies how much to swap)
        uint256 swapAmount0; // Amount of token0 to swap (0 = no swap)
        bytes swapData0; // Swap data for token0 -> asset
        // Swap parameters for token1 -> asset
        uint256 swapAmount1; // Amount of token1 to swap (0 = no swap)
        bytes swapData1; // Swap data for token1 -> asset
        uint64 rewardX64;
        uint256 deadline;
    }

    // Internal state during execution
    struct ExecuteState {
        address token0;
        address token1;
        uint24 fee;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAmount0;
        uint256 feeAmount1;
        address asset;
        uint256 debt;
        uint256 assetAmount;
        address owner;
    }

    // tokenId => vault => config
    mapping(uint256 => mapping(address => PositionConfig)) public positionConfigs;

    constructor(
        INonfungiblePositionManager _npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Automator(_npm, _operator, _withdrawer, _TWAPSeconds, _maxTWAPTickDifference, _universalRouter, _zeroxAllowanceHolder) {}

    /// @notice Configure auto-exit for a vault position
    /// @param tokenId The NFT token ID of the position
    /// @param vault The vault address where the position is collateralized
    /// @param config The auto-exit configuration
    function configToken(uint256 tokenId, address vault, PositionConfig calldata config) external {
        if (!vaults[vault]) {
            revert Unauthorized();
        }

        // Validate caller is owner of position in vault
        address owner = IVault(vault).ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        // Validate config
        if (config.isActive) {
            // Tick triggers must have valid ordering
            if (config.token0TriggerTick >= config.token1TriggerTick) {
                revert InvalidConfig();
            }
            // Note: maxDebtRatioX32 is uint32, so it's always < Q32 (2^32), no validation needed
        }

        positionConfigs[tokenId][vault] = config;

        emit PositionConfigured(
            tokenId,
            vault,
            config.isActive,
            config.token0TriggerTick,
            config.token1TriggerTick,
            config.maxDebtRatioX32,
            config.maxSlippageX64,
            config.onlyFees,
            config.maxRewardX64
        );
    }

    /// @notice Execute auto-exit through vault transform
    /// @dev Called by operators to trigger auto-exit for a position
    /// @param params Execution parameters including swap data
    function executeWithVault(ExecuteParams calldata params) external {
        if (!operators[msg.sender] || !vaults[params.vault]) {
            revert Unauthorized();
        }
        IVault(params.vault).transform(params.tokenId, address(this), abi.encodeCall(AutoExitTransformer.execute, (params)));
    }

    /// @notice Execute auto-exit (called via vault.transform)
    /// @param params Execution parameters
    function execute(ExecuteParams calldata params) external nonReentrant {
        // Must be called from vault via transform
        if (!vaults[msg.sender]) {
            revert Unauthorized();
        }
        _validateCaller(nonfungiblePositionManager, params.tokenId);

        address vault = msg.sender;
        PositionConfig memory config = positionConfigs[params.tokenId][vault];

        if (!config.isActive) {
            revert NotConfigured();
        }

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        ExecuteState memory state;
        state.asset = IVault(vault).asset();

        // Get position info
        (,, state.token0, state.token1, state.fee,,, state.liquidity,,,,) =
            nonfungiblePositionManager.positions(params.tokenId);

        if (state.liquidity == 0) {
            revert NoLiquidity();
        }

        // Check trigger conditions
        (bool triggered,) = _checkTriggerConditions(params.tokenId, vault, config, state.token0, state.token1, state.fee);
        if (!triggered) {
            revert NotReady();
        }

        // Get debt info
        (state.debt,,,,) = IVault(vault).loanInfo(params.tokenId);

        // Decrease full liquidity and collect fees
        (state.amount0, state.amount1, state.feeAmount0, state.feeAmount1) = _decreaseFullLiquidityAndCollect(
            params.tokenId, state.liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline
        );

        // Calculate and deduct operator reward
        if (config.onlyFees) {
            uint256 reward0 = state.feeAmount0 * params.rewardX64 / Q64;
            uint256 reward1 = state.feeAmount1 * params.rewardX64 / Q64;
            state.amount0 -= reward0;
            state.amount1 -= reward1;
        } else {
            state.amount0 -= state.amount0 * params.rewardX64 / Q64;
            state.amount1 -= state.amount1 * params.rewardX64 / Q64;
        }

        // Collect asset amount if one of the tokens is the asset
        state.assetAmount = 0;
        if (state.token0 == state.asset) {
            state.assetAmount = state.amount0;
            state.amount0 = 0;
        } else if (state.token1 == state.asset) {
            state.assetAmount = state.amount1;
            state.amount1 = 0;
        }

        // Perform swaps as specified by operator (for debt repayment)
        // Get oracle prices for slippage protection (price0X96 and price1X96 are in asset terms)
        uint256 price0X96;
        uint256 price1X96;
        if ((params.swapAmount0 > 0 && params.swapData0.length > 0) || (params.swapAmount1 > 0 && params.swapData1.length > 0)) {
            (,, price0X96, price1X96) = IVault(vault).oracle().getValue(params.tokenId, state.asset);
        }

        // Swap token0 -> asset if requested
        if (params.swapAmount0 > 0 && params.swapData0.length > 0) {
            uint256 swapAmount0 = params.swapAmount0 > state.amount0 ? state.amount0 : params.swapAmount0;
            if (swapAmount0 > 0) {
                // Calculate minimum output based on oracle price and configured slippage
                // amountOutMin = swapAmount * price0X96 / Q96 * (Q64 - maxSlippageX64) / Q64
                uint256 amountOutMin = FullMath.mulDiv(swapAmount0 * (Q64 - config.maxSlippageX64), price0X96, Q160);
                (uint256 amountIn, uint256 amountOut) = _routerSwap(
                    Swapper.RouterSwapParams(
                        IERC20(state.token0),
                        IERC20(state.asset),
                        swapAmount0,
                        amountOutMin,
                        params.swapData0
                    )
                );
                state.assetAmount += amountOut;
                state.amount0 -= amountIn;
            }
        }

        // Swap token1 -> asset if requested
        if (params.swapAmount1 > 0 && params.swapData1.length > 0) {
            uint256 swapAmount1 = params.swapAmount1 > state.amount1 ? state.amount1 : params.swapAmount1;
            if (swapAmount1 > 0) {
                // Calculate minimum output based on oracle price and configured slippage
                uint256 amountOutMin = FullMath.mulDiv(swapAmount1 * (Q64 - config.maxSlippageX64), price1X96, Q160);
                (uint256 amountIn, uint256 amountOut) = _routerSwap(
                    Swapper.RouterSwapParams(
                        IERC20(state.token1),
                        IERC20(state.asset),
                        swapAmount1,
                        amountOutMin,
                        params.swapData1
                    )
                );
                state.assetAmount += amountOut;
                state.amount1 -= amountIn;
            }
        }

        // Repay full debt - must have enough asset
        uint256 repaidAmount = 0;
        if (state.debt > 0) {
            if (state.assetAmount < state.debt) {
                revert InsufficientAssetForRepay();
            }
            SafeERC20.safeIncreaseAllowance(IERC20(state.asset), vault, state.debt);
            (repaidAmount,) = IVault(vault).repay(params.tokenId, state.debt, false);
            SafeERC20.safeApprove(IERC20(state.asset), vault, 0);
            state.assetAmount -= repaidAmount;
        }

        // Get position owner and return remaining funds
        state.owner = IVault(vault).ownerOf(params.tokenId);

        if (state.assetAmount > 0) {
            _transferToken(state.owner, IERC20(state.asset), state.assetAmount, true);
        }
        if (state.amount0 > 0) {
            _transferToken(state.owner, IERC20(state.token0), state.amount0, true);
        }
        if (state.amount1 > 0) {
            _transferToken(state.owner, IERC20(state.token1), state.amount1, true);
        }

        // Clear configuration
        delete positionConfigs[params.tokenId][vault];

        emit PositionConfigured(params.tokenId, vault, false, 0, 0, 0, 0, false, 0);

        emit AutoExitExecuted(
            params.tokenId,
            vault,
            state.owner,
            repaidAmount,
            state.amount0,
            state.amount1,
            state.token0,
            state.token1
        );
    }

    /// @notice Check if a position can be executed
    /// @param tokenId The NFT token ID
    /// @param vault The vault address
    /// @return triggered Whether the position is triggered for exit
    /// @return status The execute status indicating trigger reason or why not ready
    function canExecute(uint256 tokenId, address vault) external view returns (bool triggered, ExecuteStatus status) {
        PositionConfig memory config = positionConfigs[tokenId][vault];

        if (!config.isActive) {
            return (false, ExecuteStatus.NOT_CONFIGURED);
        }

        // Get position info
        (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) =
            nonfungiblePositionManager.positions(tokenId);

        if (liquidity == 0) {
            return (false, ExecuteStatus.NO_LIQUIDITY);
        }

        return _checkTriggerConditions(tokenId, vault, config, token0, token1, fee);
    }

    /// @dev Check trigger conditions for a position
    function _checkTriggerConditions(
        uint256 tokenId,
        address vault,
        PositionConfig memory config,
        address token0,
        address token1,
        uint24 fee
    ) internal view returns (bool triggered, ExecuteStatus status) {
        // Check tick trigger
        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        (, int24 currentTick,,,,,) = pool.slot0();

        if (currentTick < config.token0TriggerTick) {
            return (true, ExecuteStatus.TOKEN0_TICK_TRIGGER);
        }
        if (currentTick >= config.token1TriggerTick) {
            return (true, ExecuteStatus.TOKEN1_TICK_TRIGGER);
        }

        // Check debt ratio trigger
        if (config.maxDebtRatioX32 != 0) {
            (uint256 debt,, uint256 collateralValue,,) = IVault(vault).loanInfo(tokenId);
            if (collateralValue > 0) {
                uint256 debtRatioX32 = debt * Q32 / collateralValue;
                if (debtRatioX32 > config.maxDebtRatioX32) {
                    return (true, ExecuteStatus.DEBT_RATIO_TRIGGER);
                }
            }
        }

        return (false, ExecuteStatus.NOT_READY);
    }
}
