// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-periphery/interfaces/external/IWETH9.sol";

import "../../lib/IUniversalRouter.sol";

abstract contract Transformer {

    error SwapFailed();
    error SlippageError();
    error WrongContract();

    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// @notice Wrapped native token address
    IWETH9 immutable public weth;

    address immutable public factory;

    /// @notice Uniswap v3 position manager
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    /// @notice 0x Exchange Proxy
    address immutable public zeroxRouter;

    /// @notice Uniswap Universal Router
    address immutable public universalRouter;


    /// @notice Constructor
    /// @param _nonfungiblePositionManager Uniswap v3 position manager
    /// @param _zeroxRouter 0x Exchange Proxy
    constructor(INonfungiblePositionManager _nonfungiblePositionManager, address _zeroxRouter, address _universalRouter) {
        weth = IWETH9(_nonfungiblePositionManager.WETH9());
        factory = _nonfungiblePositionManager.factory();
        nonfungiblePositionManager = _nonfungiblePositionManager;
        zeroxRouter = _zeroxRouter;
        universalRouter = _universalRouter;
    }

    // swap data for 0x
    struct ZeroxRouterData {
        address allowanceTarget;
        bytes data;
    }

    // swap data for uni - must include sweep for input token
    struct UniversalRouterData {
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

     // general swap function which uses external router with off-chain calculated swap instructions
    // does slippage check with amountOutMin param
    // returns token amounts deltas after swap
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory swapData) internal returns (uint256 amountInDelta, uint256 amountOutDelta) {
        if (amountIn != 0 && swapData.length != 0 && address(tokenOut) != address(0)) {

            uint256 balanceInBefore = tokenIn.balanceOf(address(this));
            uint256 balanceOutBefore = tokenOut.balanceOf(address(this));

            // get router specific swap data
            (address router, bytes memory routerData) = abi.decode(swapData, (address, bytes));

            if (router == zeroxRouter) {
                ZeroxRouterData memory data = abi.decode(routerData, (ZeroxRouterData));
                // approve needed amount
                SafeERC20.safeApprove(tokenIn, data.allowanceTarget, amountIn);
                // execute swap
                (bool success,) = zeroxRouter.call(data.data);
                if (!success) {
                    revert SwapFailed();
                }
                // reset approval
                SafeERC20.safeApprove(tokenIn, data.allowanceTarget, 0);
            } else if (router == universalRouter) {
                UniversalRouterData memory data = abi.decode(routerData, (UniversalRouterData));
                // tokens are transfered to Universalrouter directly (data.commands must include sweep action!)
                SafeERC20.safeTransfer(tokenIn, universalRouter, amountIn);
                IUniversalRouter(universalRouter).execute(data.commands, data.inputs, data.deadline);
            } else {
                revert WrongContract();
            }
           
            uint256 balanceInAfter = tokenIn.balanceOf(address(this));
            uint256 balanceOutAfter = tokenOut.balanceOf(address(this));

            amountInDelta = balanceInBefore - balanceInAfter;
            amountOutDelta = balanceOutAfter - balanceOutBefore;

            // amountMin slippage check
            if (amountOutDelta < amountOutMin) {
                revert SlippageError();
            }

            // event for any swap with exact swapped value
            emit Swap(address(tokenIn), address(tokenOut), amountInDelta, amountOutDelta);
        }
    }
}