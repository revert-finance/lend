// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/interfaces/callback/IUniswapV3FlashCallback.sol";

import "../interfaces/IVault.sol";
import "./Swapper.sol";

/// @title Helper contract which allows atomic liquidation and needed swaps by using UniV3 Flashloan
contract FlashloanLiquidator is Swapper, IUniswapV3FlashCallback {
    address private activeFlashPool;
    bytes32 private activeFlashDataHash;

    struct FlashCallbackData {
        uint256 tokenId;
        uint256 liquidationCost;
        IVault vault;
        IUniswapV3Pool flashLoanPool;
        IERC20 asset;
        RouterSwapParams swap0;
        RouterSwapParams swap1;
        address liquidator;
        uint256 minReward;
        uint256 deadline;
    }

    constructor(
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder
    )
        Swapper(_nonfungiblePositionManager, _universalRouter, _zeroxAllowanceHolder)
    {}

    struct LiquidateParams {
        uint256 tokenId; // loan to liquidate
        IVault vault; // vault where the loan is
        IUniswapV3Pool flashLoanPool; // pool which is used for flashloan - may not be used in the swaps below
        uint256 amount0In; // how much of token0 to swap to asset (0 if no swap should be done)
        bytes swapData0; // swap data for token0 swap
        uint256 amount1In; // how much of token1 to swap to asset (0 if no swap should be done)
        bytes swapData1; // swap data for token1 swap
        uint256 minReward; // min reward amount (works as a global slippage control for complete operation)
        uint256 deadline; // deadline for uniswap operations
    }

    /// @notice Liquidates a loan, using a Uniswap Flashloan
    function liquidate(LiquidateParams calldata params) external {
        if (activeFlashPool != address(0)) {
            revert Unauthorized();
        }

        (,,, uint256 liquidationCost, uint256 liquidationValue) = params.vault.loanInfo(params.tokenId);
        if (liquidationValue == 0) {
            revert NotLiquidatable();
        }

        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(params.tokenId);
        address asset = params.vault.asset();

        address flashToken0 = params.flashLoanPool.token0();
        address flashToken1 = params.flashLoanPool.token1();
        bool isAsset0 = flashToken0 == asset;
        if (!isAsset0 && flashToken1 != asset) {
            revert InvalidPool();
        }
        bytes memory data = abi.encode(
            FlashCallbackData(
                params.tokenId,
                liquidationCost,
                params.vault,
                params.flashLoanPool,
                IERC20(asset),
                RouterSwapParams(IERC20(token0), IERC20(asset), params.amount0In, 0, params.swapData0),
                RouterSwapParams(IERC20(token1), IERC20(asset), params.amount1In, 0, params.swapData1),
                msg.sender,
                params.minReward,
                params.deadline
            )
        );
        activeFlashPool = address(params.flashLoanPool);
        activeFlashDataHash = keccak256(data);
        params.flashLoanPool.flash(address(this), isAsset0 ? liquidationCost : 0, !isAsset0 ? liquidationCost : 0, data);
        activeFlashPool = address(0);
        activeFlashDataHash = bytes32(0);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata callbackData) external override {
        if (msg.sender != activeFlashPool || keccak256(callbackData) != activeFlashDataHash) {
            revert Unauthorized();
        }

        FlashCallbackData memory data = abi.decode(callbackData, (FlashCallbackData));
        if (msg.sender != address(data.flashLoanPool)) {
            revert Unauthorized();
        }

        address poolToken0 = data.flashLoanPool.token0();
        address poolToken1 = data.flashLoanPool.token1();
        if (address(_getPool(poolToken0, poolToken1, data.flashLoanPool.fee())) != msg.sender) {
            revert Unauthorized();
        }
        if (address(data.asset) != poolToken0 && address(data.asset) != poolToken1) {
            revert InvalidPool();
        }

        SafeERC20.safeIncreaseAllowance(data.asset, address(data.vault), data.liquidationCost);
        data.vault.liquidate(
            IVault.LiquidateParams(
                data.tokenId, data.swap0.amountIn, data.swap1.amountIn, address(this), "", data.deadline
            )
        );
        SafeERC20.safeApprove(data.asset, address(data.vault), 0);

        // do swaps
        _routerSwap(data.swap0);
        _routerSwap(data.swap1);

        // transfer lent amount + fee (only one token can have fee) - back to pool
        SafeERC20.safeTransfer(data.asset, msg.sender, data.liquidationCost + (fee0 + fee1));

        uint256 balance;

        // return all leftover tokens to liquidator
        if (data.swap0.tokenIn != data.asset) {
            balance = data.swap0.tokenIn.balanceOf(address(this));
            if (balance != 0) {
                SafeERC20.safeTransfer(data.swap0.tokenIn, data.liquidator, balance);
            }
        }
        if (data.swap1.tokenIn != data.asset) {
            balance = data.swap1.tokenIn.balanceOf(address(this));
            if (balance != 0) {
                SafeERC20.safeTransfer(data.swap1.tokenIn, data.liquidator, balance);
            }
        }
        {
            balance = data.asset.balanceOf(address(this));
            if (balance < data.minReward) {
                revert NotEnoughReward();
            }
            if (balance != 0) {
                SafeERC20.safeTransfer(data.asset, data.liquidator, balance);
            }
        }
    }
}
