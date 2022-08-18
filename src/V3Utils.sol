// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./external/uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import "./external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./external/openzeppelin/token/ERC20/utils/SafeERC20.sol";

import "./ISwapRouter.sol";

contract V3Utils {
    IERC20 immutable public weth;
    IUniswapV3Factory immutable public factory;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    ISwapRouter immutable public swapRouter; // ISwapRouter maybe Uniswap or 1Inch or something else

    // TODO implement fee logic

    constructor(IERC20 _weth, IUniswapV3Factory _factory, INonfungiblePositionManager _nonfungiblePositionManager, ISwapRouter _swapRouter) {
        weth = _weth;
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
    }

    enum WhatToDo {
        NOTHING,
        CHANGE_RANGE,
        WITHDRAW_AND_SWAP,            
        COLLECT_AND_SWAP
    }

    struct Instructions {
        WhatToDo whatToDo;

        // target token for swaps
        address target;

        // if token0 needs to be swapped to target - set values
        uint amountIn0;
        bytes swapData0;

        // if token1 needs to be swapped to target - set values
        uint amountIn1;
        bytes swapData1;

        // for creating new positions
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        bool burnOrReturn;
        
        // for liquidity operations
        uint deadline;

        // data sent when token returned (optional)
        bytes returnData;
    }

    function onERC721Received(address , address from, uint256 tokenId, bytes calldata data) external  {

        Instructions memory instructions = abi.decode(data, (Instructions));

        (,,address token0,address token1,,,,uint128 liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);

        if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {
            _decreaseAllLiquidity(tokenId, liquidity, instructions.deadline);
            (uint amount0, uint amount1) = _collectAllFees(tokenId, IERC20(token0), IERC20(token1));
            if (instructions.target == token0) {
                _swapAndMint(SwapAndMintParams(IERC20(token0), IERC20(token1), instructions.fee, instructions.tickLower, instructions.tickUpper, amount0, amount1, from, instructions.deadline, instructions.swapData1, false, instructions.amountIn1));
            } else if (instructions.target == token1) {
                _swapAndMint(SwapAndMintParams(IERC20(token0), IERC20(token1), instructions.fee, instructions.tickLower, instructions.tickUpper, amount0, amount1, from, instructions.deadline, instructions.swapData0, true, instructions.amountIn0));
            } else {
                revert("invalid target");
            }

            if (instructions.burnOrReturn) {
                _burn(tokenId);
            } else {
                nonfungiblePositionManager.safeTransferFrom(address(this), from, tokenId, instructions.returnData);
            }
        } else if (instructions.whatToDo == WhatToDo.COLLECT_AND_SWAP || instructions.whatToDo == WhatToDo.WITHDRAW_AND_SWAP) {
            if (instructions.whatToDo == WhatToDo.WITHDRAW_AND_SWAP) {
                _decreaseAllLiquidity(tokenId, liquidity, instructions.deadline);
            }
            (uint fees0, uint fees1) = _collectAllFees(tokenId, IERC20(token0), IERC20(token1));
            uint targetAmount;
            if (token0 != instructions.target) {
                (uint amountInDelta, uint256 amountOutDelta) = _swap(IERC20(token0), IERC20(instructions.target), fees0, instructions.swapData0);
                if (amountInDelta < fees0) {
                    SafeERC20.safeTransfer(IERC20(token0), from, fees0 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += fees0; 
            }
            if (token1 != instructions.target) {
                (uint amountInDelta, uint256 amountOutDelta) = _swap(IERC20(token1), IERC20(instructions.target), fees1, instructions.swapData1);
                if (amountInDelta < fees1) {
                    SafeERC20.safeTransfer(IERC20(token1), from, fees1 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += fees1; 
            }

            SafeERC20.safeTransfer(IERC20(instructions.target), from, targetAmount);
            nonfungiblePositionManager.safeTransferFrom(address(this), from, tokenId, instructions.returnData);
        } else {
            // in any other case just return token again
            nonfungiblePositionManager.safeTransferFrom(address(this), from, tokenId, instructions.returnData);
        }        
    }

    struct SwapAndMintParams {
        IERC20 token0;
        IERC20 token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        address recipient;
        uint256 deadline;
        bytes swapData;
        bool swap0For1;
        uint amountIn;
    }

    function swapAndMint(SwapAndMintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        require(params.token0 != params.token1, "token0==token1");
        _prepareAdd(params.token0, params.token1, params.amount0, params.amount1);
        (tokenId, liquidity, amount0, amount1) = _swapAndMint(params);
    }

    struct SwapAndIncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0;
        uint256 amount1;
        uint256 deadline;
        bytes swapData;
        bool swap0For1;
        uint amountIn;
    }

    function swapAndIncreaseLiquidity(SwapAndIncreaseLiquidityParams calldata params) external payable returns ( uint128 liquidity, uint256 amount0, uint256 amount1) {
        (, , address token0, address token1, , , , , , , , ) = nonfungiblePositionManager.positions(params.tokenId);
        _prepareAdd(IERC20(token0), IERC20(token1), params.amount0, params.amount1);
        (liquidity, amount0, amount1) = _swapAndIncrease(params, IERC20(token0), IERC20(token1));
    }

    // checks if required amounts are provided and are exact - wraps any provided ETH as WETH
    // if less or more provided reverts
    function _prepareAdd(IERC20 token0, IERC20 token1, uint amount0, uint amount1) internal
    {
        uint amountAdded0;
        uint amountAdded1;

        // wrap ether sent
        if (msg.value > 0) {
            (bool success,) = payable(address(weth)).call{ value: msg.value }("");
            require(success, "eth wrap fail");

            if (weth == token0) {
                amountAdded0 = msg.value;
                require(amountAdded0 <= amount0, "msg.value>amount0");
            } else if (weth == token1) {
                amountAdded1 = msg.value;
                require(amountAdded1 <= amount1, "msg.value>amount1");
            } else {
                revert("no weth token");
            }
        }

        // get missing tokens (fails if not enough provided)
        if (amount0 > amountAdded0) {
            uint balanceBefore = token0.balanceOf(address(this));
            token0.transferFrom(msg.sender, address(this), amount0 - amountAdded0);
            uint balanceAfter = token0.balanceOf(address(this));
            require(balanceAfter - balanceBefore == amount0 - amountAdded0, "transfer error"); // catches any problems with deflationary or fee tokens
        }
        if (amount1 > amountAdded1) {
            uint balanceBefore = token1.balanceOf(address(this));
            token1.transferFrom(msg.sender, address(this), amount1 - amountAdded1);
            uint balanceAfter = token1.balanceOf(address(this));
            require(balanceAfter - balanceBefore == amount1 - amountAdded1, "transfer error"); // catches any problems with deflationary or fee tokens
        }
    }

    function _burn(uint tokenId) internal {
        nonfungiblePositionManager.burn(tokenId);
    }

    function _swapAndMint(SwapAndMintParams memory params) internal returns (uint tokenId, uint128 liquidity, uint added0, uint added1) {

        uint amount0 = params.amount0;
        uint amount1 = params.amount1;

        if (params.swap0For1) { 
            (uint amountInDelta, uint256 amountOutDelta) = _swap(params.token0, params.token1, params.amountIn, params.swapData);
            amount0 -= amountInDelta;
            amount1 += amountOutDelta;
        } else {
            (uint amountInDelta, uint256 amountOutDelta) = _swap(params.token1, params.token0, params.amountIn, params.swapData);
            amount1 -= amountInDelta;
            amount0 += amountOutDelta;
        }

        params.token0.approve(address(nonfungiblePositionManager), amount0);
        params.token1.approve(address(nonfungiblePositionManager), amount1);

        INonfungiblePositionManager.MintParams memory mintParams = 
            INonfungiblePositionManager.MintParams(
                address(params.token0), 
                address(params.token1), 
                params.fee, 
                params.tickLower, 
                params.tickUpper,
                amount0,
                amount1, 
                0,
                0,
                params.recipient,
                params.deadline
            );

        (tokenId,liquidity,added0,added1) = nonfungiblePositionManager.mint(mintParams);

        // return leftovers
        if (added0 < amount0) {
            SafeERC20.safeTransfer(params.token0, params.recipient, amount0 - added0);
        }
        if (added1 < amount1) {
            SafeERC20.safeTransfer(params.token1, params.recipient, amount1 - added1);
        }
    }

    function _swapAndIncrease(SwapAndIncreaseLiquidityParams memory params, IERC20 token0, IERC20 token1) internal returns (uint128 liquidity, uint added0, uint added1) {

        uint amount0 = params.amount0;
        uint amount1 = params.amount1;

        if (params.swap0For1) { 
            (uint amountInDelta, uint256 amountOutDelta) = _swap(token0, token1, params.amountIn, params.swapData);
            amount0 -= amountInDelta;
            amount1 += amountOutDelta;
        } else {
            (uint amountInDelta, uint256 amountOutDelta) = _swap(token1, token0, params.amountIn, params.swapData);
            amount1 -= amountInDelta;
            amount0 += amountOutDelta;
        }

        token0.approve(address(nonfungiblePositionManager), amount0);
        token1.approve(address(nonfungiblePositionManager), amount1);
        
        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLiquidityParams = 
            INonfungiblePositionManager.IncreaseLiquidityParams(
                params.tokenId, 
                amount0, 
                amount1, 
                0, 
                0, 
                params.deadline
            );

        (liquidity, added0, added1) = nonfungiblePositionManager.increaseLiquidity(increaseLiquidityParams);

        // return leftovers
        if (added0 < amount0) {
            SafeERC20.safeTransfer(token0, msg.sender, amount0 - added0);
        }
        if (added1 < amount1) {
            SafeERC20.safeTransfer(token1, msg.sender, amount1 - added1);
        }
    }

    // general swap function which uses external router with off-chain calculated swap instrucctions
    // returns new token amounts after swap
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, bytes memory swapData) internal returns (uint amountInDelta, uint256 amountOutDelta) {
        if (amountIn > 0) {
            uint balanceInBefore = tokenIn.balanceOf(address(this));
            uint balanceOutBefore = tokenOut.balanceOf(address(this));
            tokenIn.approve(address(swapRouter), amountIn);
            amountOutDelta = swapRouter.swap(swapData);
            uint balanceInAfter = tokenIn.balanceOf(address(this));
            uint balanceOutAfter = tokenOut.balanceOf(address(this));
            amountInDelta = balanceInBefore - balanceInAfter;
            require(balanceOutAfter - balanceOutBefore == amountOutDelta, "swap error"); // catches any problems with deflationary or fee tokens
        }
    }

    function _decreaseAllLiquidity(uint tokenId, uint128 liquidity, uint deadline) internal {
       nonfungiblePositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(
                tokenId, 
                liquidity, 
                0, 
                0,
                deadline
            )
        );
    }

    function _collectAllFees(uint tokenId, IERC20 token0, IERC20 token1) internal returns (uint256 amount0, uint256 amount1) {
        uint balanceBefore0 = token0.balanceOf(address(this));
        uint balanceBefore1 = token1.balanceOf(address(this));
        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)
        );
        uint balanceAfter0 = token0.balanceOf(address(this));
        uint balanceAfter1 = token1.balanceOf(address(this));
        require(balanceAfter0 - balanceBefore0 == amount0, "collect error token 0"); // catches any problems with deflationary or fee tokens
        require(balanceAfter1 - balanceBefore1 == amount1, "collect error token 1"); // catches any problems with deflationary or fee tokens
    }
}