// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Pool.sol";

import "../interfaces/IVault.sol";
import "./Swapper.sol";

import "forge-std/console.sol";

// Helper contract which does atomic liquidation by using UniV3 Flashloan
contract Liquidator is Swapper {

    error NotLiquidatable();

    struct FlashCallbackData {
        uint tokenId;
        uint liquidationCost;
        IVault vault;
        IERC20 asset;
        IUniswapV3Pool pool;
        RouterSwapParams swap0;
        RouterSwapParams swap1;
        address liquidator;
    }

    constructor(INonfungiblePositionManager _nonfungiblePositionManager, address _zeroxRouter, address _universalRouter) Swapper(_nonfungiblePositionManager, _zeroxRouter, _universalRouter) {

    }

    function liquidate(uint tokenId, IVault vault, IUniswapV3Pool flashLoanPool, RouterSwapParams memory swap0, RouterSwapParams memory swap1) external {
        (,,,uint liquidationCost,) = vault.loanInfo(tokenId);
        if (liquidationCost == 0) {
            revert NotLiquidatable();
        }

        address asset = vault.asset();
        bool isAsset0 = flashLoanPool.token0() == asset;
        bytes memory data = abi.encode(FlashCallbackData(tokenId, liquidationCost, vault, IERC20(asset), flashLoanPool, swap0, swap1, msg.sender));
        flashLoanPool.flash(address(this), isAsset0 ? liquidationCost : 0, !isAsset0 ? liquidationCost : 0, data);
    }

    function uniswapV3FlashCallback(uint fee0, uint fee1, bytes calldata callbackData) external {

        // doesn't need check because it doesn't hold funds - so no transfer of funds may be done
        FlashCallbackData memory data = abi.decode(callbackData, (FlashCallbackData));

        SafeERC20.safeApprove(data.asset, address(data.vault), data.liquidationCost);
        (uint amount0, uint amount1) = data.vault.liquidate(data.tokenId);
        SafeERC20.safeApprove(data.asset, address(data.vault), 0);

        // do swaps
        _routerSwap(data.swap0);
        _routerSwap(data.swap1);

        // transfer lent amount + fee (only one token can have fee)
        SafeERC20.safeTransfer(data.asset, address(data.pool), data.liquidationCost + (fee0 + fee1));

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
            if (balance > 0) {
                SafeERC20.safeTransfer(data.asset, data.liquidator, balance);
            }
        }

    }
}