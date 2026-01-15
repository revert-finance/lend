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
        bool swapToken0,
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
        // Swap config
        bool swapToken0; // If true, swap token0 for debt repayment; if false, swap token1
        // Reward config
        bool onlyFees; // If true, reward only from fees (not principal)
        uint64 maxRewardX64; // Max reward percentage for operator
    }

    /// @notice Parameters for execute function
    struct ExecuteParams {
        uint256 tokenId;
        address vault;
        bytes swapData; // Swap data for non-asset token -> asset (only used if needed for debt repayment)
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 amountOutMin; // Minimum output for swap (slippage protection)
        uint64 rewardX64;
        uint256 deadline;
    }

    // Internal state during execution
    struct ExecuteState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAmount0;
        uint256 feeAmount1;
        address asset;
        uint256 debt;
        uint256 assetAmount;
        address owner;
        IUniswapV3Pool pool;
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
            config.swapToken0,
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
        (,, state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity,,,,) =
            nonfungiblePositionManager.positions(params.tokenId);

        if (state.liquidity == 0) {
            revert NoLiquidity();
        }

        // Check trigger conditions
        state.pool = _getPool(state.token0, state.token1, state.fee);
        (, state.currentTick,,,,,) = state.pool.slot0();

        bool tickTriggered = state.currentTick < config.token0TriggerTick || state.currentTick >= config.token1TriggerTick;
        bool debtRatioTriggered = false;

        if (config.maxDebtRatioX32 != 0) {
            uint256 collateralValue;
            (state.debt,, collateralValue,,) = IVault(vault).loanInfo(params.tokenId);
            if (collateralValue > 0) {
                uint256 debtRatioX32 = state.debt * Q32 / collateralValue;
                debtRatioTriggered = debtRatioX32 > config.maxDebtRatioX32;
            }
        } else {
            (state.debt,,,,) = IVault(vault).loanInfo(params.tokenId);
        }

        if (!tickTriggered && !debtRatioTriggered) {
            revert NotReady();
        }

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

        // Determine which token to swap based on config
        state.assetAmount = 0;
        address swapToken;
        uint256 swapAmount;

        if (state.token0 == state.asset) {
            // token0 is the asset - use it directly, swap token1 if needed
            state.assetAmount = state.amount0;
            state.amount0 = 0;
            swapToken = state.token1;
            swapAmount = state.amount1;
        } else if (state.token1 == state.asset) {
            // token1 is the asset - use it directly, swap token0 if needed
            state.assetAmount = state.amount1;
            state.amount1 = 0;
            swapToken = state.token0;
            swapAmount = state.amount0;
        } else {
            // Neither token is the asset - swap based on config.swapToken0
            if (config.swapToken0) {
                swapToken = state.token0;
                swapAmount = state.amount0;
            } else {
                swapToken = state.token1;
                swapAmount = state.amount1;
            }
        }

        // Swap only what's needed for debt repayment
        uint256 repaidAmount = 0;
        if (state.debt > 0) {
            // First use available asset amount
            if (state.assetAmount >= state.debt) {
                // Have enough asset, no swap needed
                SafeERC20.safeIncreaseAllowance(IERC20(state.asset), vault, state.debt);
                (repaidAmount,) = IVault(vault).repay(params.tokenId, state.debt, false);
                SafeERC20.safeApprove(IERC20(state.asset), vault, 0);
                state.assetAmount -= repaidAmount;
            } else {
                // Need to swap token to cover remaining debt
                // Swap token if we have swap data and swap amount
                if (params.swapData.length > 0 && swapAmount > 0) {
                    (uint256 amountIn, uint256 amountOut) = _routerSwap(
                        Swapper.RouterSwapParams(
                            IERC20(swapToken),
                            IERC20(state.asset),
                            swapAmount,
                            params.amountOutMin,
                            params.swapData
                        )
                    );

                    state.assetAmount += amountOut;

                    // Update remaining amounts
                    if (swapToken == state.token0) {
                        state.amount0 -= amountIn;
                    } else {
                        state.amount1 -= amountIn;
                    }
                }

                // Repay as much debt as possible with available asset
                uint256 repayAmount = state.debt < state.assetAmount ? state.debt : state.assetAmount;
                if (repayAmount > 0) {
                    SafeERC20.safeIncreaseAllowance(IERC20(state.asset), vault, repayAmount);
                    (repaidAmount,) = IVault(vault).repay(params.tokenId, repayAmount, false);
                    SafeERC20.safeApprove(IERC20(state.asset), vault, 0);
                    state.assetAmount -= repaidAmount;
                }
            }
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

        emit PositionConfigured(params.tokenId, vault, false, 0, 0, 0, false, false, 0);

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
    /// @return reason The trigger reason
    function canExecute(uint256 tokenId, address vault) external view returns (bool triggered, string memory reason) {
        PositionConfig memory config = positionConfigs[tokenId][vault];

        if (!config.isActive) {
            return (false, "not_configured");
        }

        // Get position info
        (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) =
            nonfungiblePositionManager.positions(tokenId);

        if (liquidity == 0) {
            return (false, "no_liquidity");
        }

        // Check tick trigger
        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        (, int24 currentTick,,,,,) = pool.slot0();

        if (currentTick < config.token0TriggerTick) {
            return (true, "token0_tick_trigger");
        }
        if (currentTick >= config.token1TriggerTick) {
            return (true, "token1_tick_trigger");
        }

        // Check debt ratio trigger
        if (config.maxDebtRatioX32 != 0) {
            (uint256 debt,, uint256 collateralValue,,) = IVault(vault).loanInfo(tokenId);
            if (collateralValue > 0) {
                uint256 debtRatioX32 = debt * Q32 / collateralValue;
                if (debtRatioX32 > config.maxDebtRatioX32) {
                    return (true, "debt_ratio_trigger");
                }
            }
        }

        return (false, "not_ready");
    }
}
