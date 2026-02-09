// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-periphery/libraries/LiquidityAmounts.sol";
import "v3-core/libraries/TickMath.sol";

import "../automators/Automator.sol";
import "../transformers/Transformer.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IConstantLeverageTransformer.sol";

/// @title ConstantLeverageTransformer
/// @notice Automatically maintains a target leverage ratio for positions in V3Vault
/// Allows operators to rebalance positions when leverage drifts outside configured thresholds
contract ConstantLeverageTransformer is IConstantLeverageTransformer, Transformer, Automator, ReentrancyGuard {
    uint16 public constant MAX_LEVERAGE_BPS = 9000; // 90% max (10x leverage)

    // Position configurations
    mapping(uint256 => LeverageConfig) public positionConfigs;

    // State during rebalance execution
    struct RebalanceState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAmount0;
        uint256 feeAmount1;
        int24 tick;
        uint160 sqrtPriceX96;
        uint256 deadline;
        address vault;
    }

    constructor(
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder
    )
        Automator(
            _nonfungiblePositionManager,
            _operator,
            _withdrawer,
            _TWAPSeconds,
            _maxTWAPTickDifference,
            _universalRouter,
            _zeroxAllowanceHolder
        )
    {}

    /// @inheritdoc IConstantLeverageTransformer
    function setPositionConfig(uint256 tokenId, address vault, LeverageConfig calldata config) external override {
        // Validate caller is position owner
        _validateOwner(nonfungiblePositionManager, tokenId, vault);

        // Validate config
        if (config.targetLeverageBps > MAX_LEVERAGE_BPS) {
            revert InvalidConfig();
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.targetLeverageBps,
            config.lowerThresholdBps,
            config.upperThresholdBps,
            config.maxSlippageX64,
            config.onlyFees,
            config.maxRewardX64
        );
    }

    /// @inheritdoc IConstantLeverageTransformer
    function checkRebalanceNeeded(uint256 tokenId, address vault)
        external
        view
        override
        returns (bool needed, bool isIncrease, uint256 currentRatioBps)
    {
        LeverageConfig memory config = positionConfigs[tokenId];

        // Not configured
        if (config.targetLeverageBps == 0) {
            return (false, false, 0);
        }

        // Get current loan state
        (uint256 debt,, uint256 collateralValue,,) = IVault(vault).loanInfo(tokenId);

        if (collateralValue == 0) {
            return (false, false, 0);
        }

        currentRatioBps = debt * 10000 / collateralValue;

        // Check if below lower threshold (need to increase leverage)
        if (currentRatioBps + config.lowerThresholdBps < config.targetLeverageBps) {
            return (true, true, currentRatioBps);
        }

        // Check if above upper threshold (need to decrease leverage)
        if (currentRatioBps > config.targetLeverageBps + config.upperThresholdBps) {
            return (true, false, currentRatioBps);
        }

        return (false, false, currentRatioBps);
    }

    /// @inheritdoc IConstantLeverageTransformer
    function rebalanceWithVault(RebalanceParams calldata params, address vault) external override {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        IVault(vault).transform(
            params.tokenId, address(this), abi.encodeCall(ConstantLeverageTransformer.rebalance, (params))
        );
    }

    /// @inheritdoc IConstantLeverageTransformer
    function rebalance(RebalanceParams calldata params) external override nonReentrant {
        // Only callable by vault via transform - operators must use rebalanceWithVault()
        if (!vaults[msg.sender]) {
            revert Unauthorized();
        }
        _validateCaller(nonfungiblePositionManager, params.tokenId);

        LeverageConfig memory config = positionConfigs[params.tokenId];
        if (config.targetLeverageBps == 0) {
            revert NotConfigured();
        }

        // Validate reward
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        RebalanceState memory state;
        state.vault = msg.sender;
        state.deadline = params.deadline;

        // Get current loan state
        (uint256 debtBefore, uint256 fullValue, uint256 collateralValue,,) = IVault(state.vault).loanInfo(params.tokenId);

        if (collateralValue == 0) {
            revert NotConfigured();
        }

        // Determine if we need to increase or decrease leverage
        bool isIncrease = _checkAndDetermineRebalanceDirection(debtBefore, collateralValue, config);

        // Get position info
        (,, state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity,,,,) =
            nonfungiblePositionManager.positions(params.tokenId);

        // Check TWAP
        _validateTWAP(state);

        uint256 reward0;
        uint256 reward1;

        if (isIncrease) {
            (reward0, reward1) = _increaseLeverage(params, config, state, debtBefore, fullValue, collateralValue);
        } else {
            (reward0, reward1) = _decreaseLeverage(params, config, state, debtBefore, fullValue, collateralValue);
        }

        (uint256 debtAfter,,,,) = IVault(state.vault).loanInfo(params.tokenId);

        emit Rebalanced(params.tokenId, isIncrease, debtBefore, debtAfter, reward0, reward1);
    }

    /// @notice Check rebalance direction and revert if not needed
    function _checkAndDetermineRebalanceDirection(
        uint256 currentDebt,
        uint256 collateralValue,
        LeverageConfig memory config
    ) internal pure returns (bool isIncrease) {
        uint256 currentRatioBps = currentDebt * 10000 / collateralValue;

        if (currentRatioBps + config.lowerThresholdBps < config.targetLeverageBps) {
            return true;
        } else if (currentRatioBps > config.targetLeverageBps + config.upperThresholdBps) {
            return false;
        }
        revert NotReady();
    }

    /// @notice Validate TWAP is within acceptable bounds
    function _validateTWAP(RebalanceState memory state) internal view {
        IUniswapV3Pool pool = _getPool(state.token0, state.token1, state.fee);
        (state.sqrtPriceX96, state.tick,,,,,) = pool.slot0();

        uint32 tSecs = TWAPSeconds;
        if (tSecs != 0) {
            if (!_hasMaxTWAPTickDifference(pool, tSecs, state.tick, maxTWAPTickDifference)) {
                revert TWAPCheckFailed();
            }
        }
    }

    /// @notice Increase leverage by borrowing more and adding liquidity
    function _increaseLeverage(
        RebalanceParams calldata params,
        LeverageConfig memory config,
        RebalanceState memory state,
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue
    ) internal returns (uint256 reward0, uint256 reward1) {
        // Calculate how much to borrow to reach target (accounts for collateral factor)
        uint256 borrowAmount = _calculateBorrowAmount(config.targetLeverageBps, currentDebt, fullValue, collateralValue);
        if (borrowAmount == 0) {
            return (0, 0);
        }

        address asset = IVault(state.vault).asset();

        // Borrow from vault
        IVault(state.vault).borrow(params.tokenId, borrowAmount);

        // Collect any pending fees first
        (state.feeAmount0, state.feeAmount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(params.tokenId, address(this), type(uint128).max, type(uint128).max)
        );

        // Start with collected fees
        state.amount0 = state.feeAmount0;
        state.amount1 = state.feeAmount1;

        // If asset is one of the position tokens, add borrowed amount directly
        if (asset == state.token0) {
            state.amount0 += borrowAmount;
        } else if (asset == state.token1) {
            state.amount1 += borrowAmount;
        }

        // Calculate and deduct reward
        (reward0, reward1) = _calculateRewardForIncrease(params.rewardX64, config.onlyFees, state);
        state.amount0 -= reward0;
        state.amount1 -= reward1;

        // Execute swaps (asset -> position tokens)
        _executeIncreaseSwaps(params, config, state, asset);

        // Add liquidity
        if (state.amount0 > 0 || state.amount1 > 0) {
            _addLiquidity(params.tokenId, state);
        }

        // Send leftover tokens to position owner (rewards stay in contract for withdrawer)
        _sendLeftoversToOwner(params.tokenId, state);
    }

    /// @notice Calculate borrow amount for increase leverage, accounting for collateral factor
    /// @dev When borrowing B, new debt = d+B and new collateralValue = c+B*(c/fv) because the
    ///      borrowed asset is added as liquidity but discounted by the collateral factor (c/fv).
    ///      Solving (d+B)/(c+B*c/fv) = t for B gives:
    ///      B = (t*c - d) * fv / (fv - t*c)  [in ratio terms]
    ///      In bps: B = (target*c - d*10000) * fv / (10000*fv - target*c)
    function _calculateBorrowAmount(
        uint16 targetLeverageBps,
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue
    ) internal pure returns (uint256 borrowAmount) {
        uint256 target = uint256(targetLeverageBps);
        uint256 targetTimesCollateral = target * collateralValue;
        uint256 denominatorBps = 10000 * fullValue;

        if (denominatorBps <= targetTimesCollateral) {
            revert InvalidConfig();
        }

        uint256 denominator = denominatorBps - targetTimesCollateral;

        uint256 numerator = targetTimesCollateral;
        uint256 debtScaled = currentDebt * 10000;
        if (numerator <= debtScaled) {
            return 0; // Already at or above target
        }

        borrowAmount = (numerator - debtScaled) * fullValue / denominator;
    }

    /// @notice Calculate reward for increase leverage (before swaps)
    function _calculateRewardForIncrease(uint64 rewardX64, bool onlyFees, RebalanceState memory state)
        internal
        pure
        returns (uint256 reward0, uint256 reward1)
    {
        if (onlyFees) {
            reward0 = state.feeAmount0 * rewardX64 / Q64;
            reward1 = state.feeAmount1 * rewardX64 / Q64;
        } else {
            reward0 = state.amount0 * rewardX64 / Q64;
            reward1 = state.amount1 * rewardX64 / Q64;
        }
    }

    /// @notice Execute swaps for increase leverage (asset -> position tokens)
    function _executeIncreaseSwaps(
        RebalanceParams calldata params,
        LeverageConfig memory config,
        RebalanceState memory state,
        address asset
    ) internal {
        // Get oracle prices for slippage validation (if any swaps needed)
        uint256 price0X96;
        uint256 price1X96;
        if ((params.swapAmount0 > 0 && params.swapData0.length > 0) ||
            (params.swapAmount1 > 0 && params.swapData1.length > 0)) {
            (,, price0X96, price1X96) = IVault(state.vault).oracle().getValue(params.tokenId, asset);
        }

        // Swap asset -> token0 if requested
        if (params.swapAmount0 > 0 && params.swapData0.length > 0) {
            _executeIncreaseSwap(state, asset, state.token0, params.swapAmount0, params.swapData0, price0X96, config.maxSlippageX64);
        }

        // Swap asset -> token1 if requested
        if (params.swapAmount1 > 0 && params.swapData1.length > 0) {
            _executeIncreaseSwap(state, asset, state.token1, params.swapAmount1, params.swapData1, price1X96, config.maxSlippageX64);
        }
    }

    /// @notice Execute single swap for increase leverage (asset -> token)
    function _executeIncreaseSwap(
        RebalanceState memory state,
        address asset,
        address tokenOut,
        uint256 swapAmount,
        bytes calldata swapData,
        uint256 priceX96,
        uint64 maxSlippageX64
    ) internal {
        // For increase: we're swapping asset IN to get token OUT
        // priceX96 = token price in asset terms, so amountOut = amountIn * Q96 / priceX96
        uint256 amountOutMin = swapAmount * Q96 / priceX96 * (Q64 - maxSlippageX64) / Q64;
        (uint256 amountIn, uint256 amountOut) = _routerSwap(
            Swapper.RouterSwapParams(IERC20(asset), IERC20(tokenOut), swapAmount, amountOutMin, swapData)
        );

        // Add output to appropriate token amount
        if (tokenOut == state.token0) {
            state.amount0 += amountOut;
        } else {
            state.amount1 += amountOut;
        }

        // Deduct input from state if asset is a position token
        if (asset == state.token0) state.amount0 -= amountIn;
        else if (asset == state.token1) state.amount1 -= amountIn;
    }

    /// @notice Decrease leverage by removing liquidity and repaying debt
    function _decreaseLeverage(
        RebalanceParams calldata params,
        LeverageConfig memory config,
        RebalanceState memory state,
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue
    ) internal returns (uint256 reward0, uint256 reward1) {
        // Calculate how much debt to repay to reach target (accounts for collateral factor)
        uint256 repayAmount = _calculateRepayAmount(config.targetLeverageBps, currentDebt, fullValue, collateralValue);
        if (repayAmount == 0) {
            return (0, 0);
        }

        address asset = IVault(state.vault).asset();

        // Calculate and remove liquidity (use fullValue for proportional calculation since
        // liquidity removal is based on actual position value, not discounted collateral)
        uint128 liquidityToRemove = _calculateLiquidityToRemove(state.liquidity, repayAmount, fullValue);
        (state.amount0, state.amount1, state.feeAmount0, state.feeAmount1) =
            _decreaseFullLiquidityAndCollect(params.tokenId, liquidityToRemove, 0, 0, state.deadline);

        // Calculate and deduct reward
        (reward0, reward1) = _calculateReward(params.rewardX64, config.onlyFees, state);
        state.amount0 -= reward0;
        state.amount1 -= reward1;

        // Collect asset amount if one of the tokens is the asset
        uint256 assetAmount = 0;
        if (asset == state.token0) {
            assetAmount = state.amount0;
            state.amount0 = 0;
        } else if (asset == state.token1) {
            assetAmount = state.amount1;
            state.amount1 = 0;
        }

        // Execute swaps (position tokens -> asset) and accumulate assetAmount
        assetAmount = _executeDecreaseSwaps(params, config, state, asset, assetAmount);

        // Repay debt and send leftovers
        uint256 assetLeftover = _repayAndCalculateLeftover(params.tokenId, state.vault, asset, assetAmount, repayAmount);

        // Send leftover tokens to position owner (rewards stay in contract for withdrawer)
        _sendLeftoversToOwner(params.tokenId, state, asset, assetLeftover);
    }

    /// @notice Execute swaps for decrease leverage (position tokens -> asset)
    function _executeDecreaseSwaps(
        RebalanceParams calldata params,
        LeverageConfig memory config,
        RebalanceState memory state,
        address asset,
        uint256 assetAmount
    ) internal returns (uint256) {
        // Get oracle prices for slippage validation (if any swaps needed)
        uint256 price0X96;
        uint256 price1X96;
        if ((params.swapAmount0 > 0 && params.swapData0.length > 0) ||
            (params.swapAmount1 > 0 && params.swapData1.length > 0)) {
            (,, price0X96, price1X96) = IVault(state.vault).oracle().getValue(params.tokenId, asset);
        }

        // Swap token0 -> asset if requested
        if (params.swapAmount0 > 0 && params.swapData0.length > 0) {
            uint256 swapAmount = params.swapAmount0 > state.amount0 ? state.amount0 : params.swapAmount0;
            if (swapAmount > 0) {
                uint256 amountOutMin = swapAmount * price0X96 / Q96 * (Q64 - config.maxSlippageX64) / Q64;
                (uint256 amountIn, uint256 amountOut) = _routerSwap(
                    Swapper.RouterSwapParams(IERC20(state.token0), IERC20(asset), swapAmount, amountOutMin, params.swapData0)
                );
                assetAmount += amountOut;
                state.amount0 -= amountIn;
            }
        }

        // Swap token1 -> asset if requested
        if (params.swapAmount1 > 0 && params.swapData1.length > 0) {
            uint256 swapAmount = params.swapAmount1 > state.amount1 ? state.amount1 : params.swapAmount1;
            if (swapAmount > 0) {
                uint256 amountOutMin = swapAmount * price1X96 / Q96 * (Q64 - config.maxSlippageX64) / Q64;
                (uint256 amountIn, uint256 amountOut) = _routerSwap(
                    Swapper.RouterSwapParams(IERC20(state.token1), IERC20(asset), swapAmount, amountOutMin, params.swapData1)
                );
                assetAmount += amountOut;
                state.amount1 -= amountIn;
            }
        }

        return assetAmount;
    }

    /// @notice Repay debt and return leftover asset amount
    function _repayAndCalculateLeftover(
        uint256 tokenId,
        address vault,
        address asset,
        uint256 assetAmount,
        uint256 repayAmount
    ) internal returns (uint256 assetLeftover) {
        if (assetAmount > 0) {
            uint256 actualRepay = assetAmount > repayAmount ? repayAmount : assetAmount;
            SafeERC20.safeIncreaseAllowance(IERC20(asset), vault, actualRepay);
            IVault(vault).repay(tokenId, actualRepay, false);
            SafeERC20.safeApprove(IERC20(asset), vault, 0);
            assetLeftover = assetAmount - actualRepay;
        }
    }

    /// @notice Calculate repay amount for decrease leverage, accounting for collateral factor
    /// @dev When repaying R, new debt = d-R and new collateralValue = c-R*(c/fv) because removed
    ///      liquidity reduces collateral by the discounted amount. Solving (d-R)/(c-R*c/fv) = t:
    ///      R = (d*10000 - target*c) * fv / (10000*fv - target*c)
    function _calculateRepayAmount(
        uint16 targetLeverageBps,
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue
    ) internal pure returns (uint256 repayAmount) {
        uint256 target = uint256(targetLeverageBps);
        uint256 targetTimesCollateral = target * collateralValue;
        uint256 denominatorBps = 10000 * fullValue;

        if (denominatorBps <= targetTimesCollateral) {
            revert InvalidConfig();
        }

        uint256 denominator = denominatorBps - targetTimesCollateral;

        uint256 debtScaled = currentDebt * 10000;
        if (debtScaled <= targetTimesCollateral) {
            return 0; // Already at or below target
        }

        repayAmount = (debtScaled - targetTimesCollateral) * fullValue / denominator;
    }

    /// @notice Calculate liquidity to remove for repay
    function _calculateLiquidityToRemove(uint128 totalLiquidity, uint256 repayAmount, uint256 collateralValue)
        internal
        pure
        returns (uint128 liquidityToRemove)
    {
        if (repayAmount >= collateralValue) {
            return totalLiquidity; // Remove all
        }
        // Remove proportional liquidity (with 10% buffer for swap slippage)
        liquidityToRemove = SafeCast.toUint128(uint256(totalLiquidity) * repayAmount * 11000 / collateralValue / 10000);
        if (liquidityToRemove > totalLiquidity) {
            liquidityToRemove = totalLiquidity;
        }
    }

    /// @notice Calculate reward amounts
    function _calculateReward(uint64 rewardX64, bool onlyFees, RebalanceState memory state)
        internal
        pure
        returns (uint256 reward0, uint256 reward1)
    {
        if (onlyFees) {
            reward0 = state.feeAmount0 * rewardX64 / Q64;
            reward1 = state.feeAmount1 * rewardX64 / Q64;
        } else {
            reward0 = state.amount0 * rewardX64 / Q64;
            reward1 = state.amount1 * rewardX64 / Q64;
        }
    }

    /// @notice Add liquidity to position
    function _addLiquidity(uint256 tokenId, RebalanceState memory state) internal {
        SafeERC20.safeIncreaseAllowance(IERC20(state.token0), address(nonfungiblePositionManager), state.amount0);
        SafeERC20.safeIncreaseAllowance(IERC20(state.token1), address(nonfungiblePositionManager), state.amount1);

        (, uint256 added0, uint256 added1) = nonfungiblePositionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams(tokenId, state.amount0, state.amount1, 0, 0, state.deadline)
        );

        // Reset approvals
        SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), 0);
        SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), 0);

        // Update amounts for leftover calculation
        state.amount0 -= added0;
        state.amount1 -= added1;
    }

    /// @notice Send leftover tokens to position owner (excluding rewards which stay in contract)
    /// @dev Used by _increaseLeverage where asset is a position token
    function _sendLeftoversToOwner(uint256 tokenId, RebalanceState memory state) internal {
        _sendLeftoversToOwner(tokenId, state, address(0), 0);
    }

    /// @notice Send leftover tokens to position owner (excluding rewards which stay in contract)
    /// @dev Used by _decreaseLeverage where asset may be different from position tokens.
    ///      Uses state.amount0/amount1 (which track only the current rebalance's deltas) instead
    ///      of contract balances to avoid draining previously accrued rewards held for the withdrawer.
    function _sendLeftoversToOwner(
        uint256 tokenId,
        RebalanceState memory state,
        address asset,
        uint256 assetLeftover
    ) internal {
        address owner = IVault(state.vault).ownerOf(tokenId);

        if (state.amount0 > 0) {
            SafeERC20.safeTransfer(IERC20(state.token0), owner, state.amount0);
        }
        if (state.amount1 > 0) {
            SafeERC20.safeTransfer(IERC20(state.token1), owner, state.amount1);
        }

        // Send asset leftovers (if different from token0/token1)
        if (asset != address(0) && asset != state.token0 && asset != state.token1 && assetLeftover > 0) {
            SafeERC20.safeTransfer(IERC20(asset), owner, assetLeftover);
        }
    }
}
