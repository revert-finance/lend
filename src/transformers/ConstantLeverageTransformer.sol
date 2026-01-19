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
    uint64 public constant MAX_REWARD_X64 = uint64(Q64 / 50); // 2% max

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
        if (config.maxRewardX64 > MAX_REWARD_X64) {
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
        (uint256 debtBefore,, uint256 collateralValue,,) = IVault(state.vault).loanInfo(params.tokenId);

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
            (reward0, reward1) = _increaseLeverage(params, config, state, debtBefore, collateralValue);
        } else {
            (reward0, reward1) = _decreaseLeverage(params, config, state, debtBefore, collateralValue);
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
        uint256 collateralValue
    ) internal returns (uint256 reward0, uint256 reward1) {
        // Calculate how much to borrow to reach target
        uint256 borrowAmount = _calculateBorrowAmount(config.targetLeverageBps, currentDebt, collateralValue);
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
        _sendLeftoversToOwner(params.tokenId, state, reward0, reward1);
    }

    /// @notice Calculate borrow amount for increase leverage
    function _calculateBorrowAmount(uint16 targetLeverageBps, uint256 currentDebt, uint256 collateralValue)
        internal
        pure
        returns (uint256 borrowAmount)
    {
        // borrowAmount = (targetRatio * collateralValue - currentDebt * 10000) / (10000 - targetRatio)
        uint256 denominator = 10000 - uint256(targetLeverageBps);
        if (denominator == 0) {
            revert InvalidConfig();
        }

        uint256 targetDebtNumerator = uint256(targetLeverageBps) * collateralValue;
        if (targetDebtNumerator <= currentDebt * 10000) {
            return 0; // Already at or above target
        }

        borrowAmount = (targetDebtNumerator - currentDebt * 10000) / denominator;
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
            _executeIncreaseSwap0(params, config.maxSlippageX64, state, asset, price0X96);
        }

        // Swap asset -> token1 if requested
        if (params.swapAmount1 > 0 && params.swapData1.length > 0) {
            _executeIncreaseSwap1(params, config.maxSlippageX64, state, asset, price1X96);
        }
    }

    /// @notice Execute swap for token0 (asset -> token0)
    function _executeIncreaseSwap0(
        RebalanceParams calldata params,
        uint64 maxSlippageX64,
        RebalanceState memory state,
        address asset,
        uint256 price0X96
    ) internal {
        // For increase: we're swapping asset IN to get token0 OUT
        // price0X96 = token0 price in asset terms, so amountOut = amountIn * Q96 / price0X96
        uint256 amountOutMin = params.swapAmount0 * Q96 / price0X96 * (Q64 - maxSlippageX64) / Q64;
        (uint256 amountIn, uint256 amountOut) = _routerSwap(
            Swapper.RouterSwapParams(
                IERC20(asset),
                IERC20(state.token0),
                params.swapAmount0,
                amountOutMin,
                params.swapData0
            )
        );
        state.amount0 += amountOut;
        // Deduct from state.amount0/1 if asset is a position token
        if (asset == state.token0) state.amount0 -= amountIn;
        else if (asset == state.token1) state.amount1 -= amountIn;
    }

    /// @notice Execute swap for token1 (asset -> token1)
    function _executeIncreaseSwap1(
        RebalanceParams calldata params,
        uint64 maxSlippageX64,
        RebalanceState memory state,
        address asset,
        uint256 price1X96
    ) internal {
        uint256 amountOutMin = params.swapAmount1 * Q96 / price1X96 * (Q64 - maxSlippageX64) / Q64;
        (uint256 amountIn, uint256 amountOut) = _routerSwap(
            Swapper.RouterSwapParams(
                IERC20(asset),
                IERC20(state.token1),
                params.swapAmount1,
                amountOutMin,
                params.swapData1
            )
        );
        state.amount1 += amountOut;
        if (asset == state.token0) state.amount0 -= amountIn;
        else if (asset == state.token1) state.amount1 -= amountIn;
    }

    /// @notice Decrease leverage by removing liquidity and repaying debt
    function _decreaseLeverage(
        RebalanceParams calldata params,
        LeverageConfig memory config,
        RebalanceState memory state,
        uint256 currentDebt,
        uint256 collateralValue
    ) internal returns (uint256 reward0, uint256 reward1) {
        // Calculate how much debt to repay to reach target
        uint256 repayAmount = _calculateRepayAmount(config.targetLeverageBps, currentDebt, collateralValue);
        if (repayAmount == 0) {
            return (0, 0);
        }

        address asset = IVault(state.vault).asset();

        // Calculate and remove liquidity
        uint128 liquidityToRemove = _calculateLiquidityToRemove(state.liquidity, repayAmount, currentDebt);
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
        _sendLeftoversToOwner(params.tokenId, state, reward0, reward1, asset, assetLeftover);
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
            assetAmount = _executeDecreaseSwap0(params, config.maxSlippageX64, state, asset, price0X96, assetAmount);
        }

        // Swap token1 -> asset if requested
        if (params.swapAmount1 > 0 && params.swapData1.length > 0) {
            assetAmount = _executeDecreaseSwap1(params, config.maxSlippageX64, state, asset, price1X96, assetAmount);
        }

        return assetAmount;
    }

    /// @notice Execute swap for token0 (token0 -> asset)
    function _executeDecreaseSwap0(
        RebalanceParams calldata params,
        uint64 maxSlippageX64,
        RebalanceState memory state,
        address asset,
        uint256 price0X96,
        uint256 assetAmount
    ) internal returns (uint256) {
        uint256 swapAmount0 = params.swapAmount0 > state.amount0 ? state.amount0 : params.swapAmount0;
        if (swapAmount0 > 0) {
            // amountOutMin = swapAmount * price0X96 / Q96 * (Q64 - maxSlippageX64) / Q64
            uint256 amountOutMin = swapAmount0 * price0X96 / Q96 * (Q64 - maxSlippageX64) / Q64;
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    IERC20(state.token0),
                    IERC20(asset),
                    swapAmount0,
                    amountOutMin,
                    params.swapData0
                )
            );
            assetAmount += amountOut;
            state.amount0 -= amountIn;
        }
        return assetAmount;
    }

    /// @notice Execute swap for token1 (token1 -> asset)
    function _executeDecreaseSwap1(
        RebalanceParams calldata params,
        uint64 maxSlippageX64,
        RebalanceState memory state,
        address asset,
        uint256 price1X96,
        uint256 assetAmount
    ) internal returns (uint256) {
        uint256 swapAmount1 = params.swapAmount1 > state.amount1 ? state.amount1 : params.swapAmount1;
        if (swapAmount1 > 0) {
            uint256 amountOutMin = swapAmount1 * price1X96 / Q96 * (Q64 - maxSlippageX64) / Q64;
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    IERC20(state.token1),
                    IERC20(asset),
                    swapAmount1,
                    amountOutMin,
                    params.swapData1
                )
            );
            assetAmount += amountOut;
            state.amount1 -= amountIn;
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

    /// @notice Calculate repay amount for decrease leverage
    function _calculateRepayAmount(uint16 targetLeverageBps, uint256 currentDebt, uint256 collateralValue)
        internal
        pure
        returns (uint256 repayAmount)
    {
        uint256 denominator = 10000 - uint256(targetLeverageBps);
        if (denominator == 0) {
            revert InvalidConfig();
        }

        uint256 targetDebtNumerator = uint256(targetLeverageBps) * collateralValue;
        if (currentDebt * 10000 <= targetDebtNumerator) {
            return 0; // Already at or below target
        }

        repayAmount = (currentDebt * 10000 - targetDebtNumerator) / denominator;
    }

    /// @notice Calculate liquidity to remove for repay
    function _calculateLiquidityToRemove(uint128 totalLiquidity, uint256 repayAmount, uint256 currentDebt)
        internal
        pure
        returns (uint128 liquidityToRemove)
    {
        if (repayAmount >= currentDebt) {
            return totalLiquidity; // Remove all
        }
        // Remove proportional liquidity (with 10% buffer for swap slippage)
        liquidityToRemove = SafeCast.toUint128(uint256(totalLiquidity) * repayAmount * 11000 / currentDebt / 10000);
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
    function _sendLeftoversToOwner(uint256 tokenId, RebalanceState memory state, uint256 reward0, uint256 reward1) internal {
        _sendLeftoversToOwner(tokenId, state, reward0, reward1, address(0), 0);
    }

    /// @notice Send leftover tokens to position owner (excluding rewards which stay in contract)
    /// @dev Used by _decreaseLeverage where asset may be different from position tokens
    function _sendLeftoversToOwner(
        uint256 tokenId,
        RebalanceState memory state,
        uint256 reward0,
        uint256 reward1,
        address asset,
        uint256 assetLeftover
    ) internal {
        address owner = IVault(state.vault).ownerOf(tokenId);

        uint256 balance0 = IERC20(state.token0).balanceOf(address(this));
        uint256 balance1 = IERC20(state.token1).balanceOf(address(this));

        // Send only leftovers, keep rewards in contract for withdrawer
        uint256 leftover0 = balance0 > reward0 ? balance0 - reward0 : 0;
        uint256 leftover1 = balance1 > reward1 ? balance1 - reward1 : 0;

        if (leftover0 > 0) {
            SafeERC20.safeTransfer(IERC20(state.token0), owner, leftover0);
        }
        if (leftover1 > 0) {
            SafeERC20.safeTransfer(IERC20(state.token1), owner, leftover1);
        }

        // Send asset leftovers (if different from token0/token1)
        if (asset != address(0) && asset != state.token0 && asset != state.token1 && assetLeftover > 0) {
            SafeERC20.safeTransfer(IERC20(asset), owner, assetLeftover);
        }
    }
}
