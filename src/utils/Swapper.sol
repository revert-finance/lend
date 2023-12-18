// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-periphery/interfaces/external/IWETH9.sol";

import "../../lib/IUniversalRouter.sol";

// base functionality to do swaps with different routing protocols
abstract contract Swapper is IUniswapV3SwapCallback {

    error SwapFailed();
    error SlippageError();
    error WrongContract();
    error Unauthorized();

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

    // execute swap directly on specified pool
    // amounts must be available on the contract for both tokens
    // slippage is not checked - so this must be executed in an oracle verified context
    function _poolSwap(IUniswapV3Pool pool, IERC20 token0, IERC20 token1, uint24 fee, bool swap0For1, uint256 amountIn) internal returns (uint256 amountInDelta, uint256 amountOutDelta) {
        if (amountIn > 0) {
            (int256 amount0Delta, int256 amount1Delta) = pool.swap(address(this), swap0For1, int256(amountIn), (swap0For1 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1), abi.encode(swap0For1 ? token0 : token1, swap0For1 ? token1 : token0, fee));
            amountInDelta = swap0For1 ? uint256(amount0Delta) : uint256(amount1Delta);
            amountOutDelta = swap0For1 ? uint256(-amount1Delta) : uint256(-amount0Delta);
        }
    }

    // swap callback function where amount for swap is payed
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {

        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported

        // check if really called from pool
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        if (address(_getPool(tokenIn, tokenOut, fee)) != msg.sender) {
            revert Unauthorized();
        }

        // transfer needed amount of tokenIn
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        SafeERC20.safeTransfer(IERC20(tokenIn), msg.sender, amountToPay);
    }

    // get pool for token
    function _getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal view returns (IUniswapV3Pool) {
        return
            IUniswapV3Pool(
                PoolAddress.computeAddress(
                    address(factory),
                    PoolAddress.getPoolKey(tokenA, tokenB, fee)
                )
            );
    }
}