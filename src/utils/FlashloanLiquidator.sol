// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/interfaces/callback/IUniswapV3FlashCallback.sol";

import "../interfaces/IVault.sol";
import "./Swapper.sol";

import "forge-std/console.sol";

// Helper contract which does atomic liquidation by using UniV3 Flashloan
contract FlashloanLiquidator is Swapper, IUniswapV3FlashCallback {

    error NotLiquidatable();
    error NotEnoughReward();

    struct FlashCallbackData {
        uint tokenId;
        uint liquidationCost;
        IVault vault;
        IERC20 asset;
        RouterSwapParams swap0;
        RouterSwapParams swap1;
        address liquidator;
        uint minReward;
    }

    constructor(INonfungiblePositionManager _nonfungiblePositionManager, address _zeroxRouter, address _universalRouter) Swapper(_nonfungiblePositionManager, _zeroxRouter, _universalRouter) {

    }

    struct LiquidateParams {
        uint tokenId; // loan to liquidate
        IVault vault; // vault where the loan is
        IUniswapV3Pool flashLoanPool; // pool which is used for flashloan - may not be used in the swaps below
        uint256 amount0In; // how much of token0 to swap to asset (0 if no swap should be done)
        bytes swapData0; // swap data for token0 swap
        uint256 amount1In; // how much of token1 to swap to asset (0 if no swap should be done)
        bytes swapData1; // swap data for token1 swap
        uint minReward; // min reward amount (works as a global slippage control for complete operation)
    }

    /// @notice Liquidates a loan, using a Uniswap Flashloan
    function liquidate(LiquidateParams calldata params) external {
        (,,,uint liquidationCost,) = params.vault.loanInfo(params.tokenId);
        if (liquidationCost == 0) {
            revert NotLiquidatable();
        }

        (,,address token0,address token1,,,,,,,,) = nonfungiblePositionManager.positions(params.tokenId);
        address asset = params.vault.asset();
        
        bool isAsset0 = params.flashLoanPool.token0() == asset;
        bytes memory data = abi.encode(FlashCallbackData(params.tokenId, liquidationCost, params.vault, IERC20(asset), RouterSwapParams(IERC20(token0), IERC20(asset), params.amount0In, 0, params.swapData0), RouterSwapParams(IERC20(token1), IERC20(asset), params.amount1In, 0, params.swapData1), msg.sender, params.minReward));
        params.flashLoanPool.flash(address(this), isAsset0 ? liquidationCost : 0, !isAsset0 ? liquidationCost : 0, data);
    }

    function uniswapV3FlashCallback(uint fee0, uint fee1, bytes calldata callbackData) external {

        // for liquidation to work, this method needs to recieve funds (so no origin check is needed)

        FlashCallbackData memory data = abi.decode(callbackData, (FlashCallbackData));

        SafeERC20.safeApprove(data.asset, address(data.vault), data.liquidationCost);
        (uint amount0, uint amount1) = data.vault.liquidate(data.tokenId);
        SafeERC20.safeApprove(data.asset, address(data.vault), 0);

        // do swaps
        _routerSwap(data.swap0);
        _routerSwap(data.swap1);

        // transfer lent amount + fee (only one token can have fee) - back to pool
        SafeERC20.safeTransfer(data.asset, msg.sender, data.liquidationCost + (fee0 + fee1));

        // return all leftover tokens to liquidator
        if (data.swap0.tokenIn != data.asset) {
            uint balance = data.swap0.tokenIn.balanceOf(address(this));
            if (balance > 0) {
                SafeERC20.safeTransfer(data.swap0.tokenIn, data.liquidator, balance);
            }
        }
        if (data.swap1.tokenIn != data.asset) {
            uint balance = data.swap1.tokenIn.balanceOf(address(this));
            if (balance > 0) {
                SafeERC20.safeTransfer(data.swap1.tokenIn, data.liquidator, balance);
            }
        }
        {
            uint balance = data.asset.balanceOf(address(this));
            if (balance < data.minReward) {
                revert NotEnoughReward();
            }
            if (balance > 0) {
                SafeERC20.safeTransfer(data.asset, data.liquidator, balance);
            }
        }
    }
}