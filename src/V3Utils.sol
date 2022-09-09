// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./external/openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "./external/openzeppelin/token/ERC721/IERC721Receiver.sol";

contract V3Utils is IERC721Receiver {

    uint256 constant private BASE = 1e18;
 
    IERC20 immutable public weth; // wrapped native token address
    INonfungiblePositionManager immutable public nonfungiblePositionManager; // uniswap v3 position manager
    address swapRouter; // the trusted contract which is allowed to do arbitrary (swap) calls - 0x for now
    uint256 immutable public protocolFeeMantissa; // the fee as a mantissa (scaled by BASE)
    address immutable public protocolFeeBeneficiary; // address recieving the protocol fee

    constructor(IERC20 _weth, INonfungiblePositionManager _nonfungiblePositionManager, address _swapRouter, uint256 _protocolFeeMantissa, address _beneficiary) {
        weth = _weth;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
        protocolFeeMantissa = _protocolFeeMantissa;
        protocolFeeBeneficiary = _beneficiary;
    }

    enum WhatToDo {
        NOTHING,
        CHANGE_RANGE,
        WITHDRAW_COLLECT_AND_SWAP
    }

    struct Instructions {
        WhatToDo whatToDo;

        // target token for swaps
        address swapTargetToken;

        // if token0 needs to be swapped to target - set values
        uint amountIn0;
        uint amountOut1Min;
        bytes swapData0;

        // if token1 needs to be swapped to target - set values
        uint amountIn1;
        uint amountOut0Min;
        bytes swapData1;

        // for creating new positions
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        bool burnNoReturn;
        
        // for liquidity operations
        uint128 liquidity;
        uint deadline;

        // data sent when token returned (optional)
        bytes returnData;
    }

    function onERC721Received(address , address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        Instructions memory instructions = abi.decode(data, (Instructions));

        (,,address token0,address token1,,,,uint128 liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);

        if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {
            _decreaseLiquidity(tokenId, liquidity, instructions.deadline);
            (uint amount0, uint amount1) = _collectAllFees(tokenId, IERC20(token0), IERC20(token1));
            if (instructions.swapTargetToken == token0) {
                require(amount1 >= instructions.amountIn1, "amountIn1>amount1");
                _swapAndMint(SwapAndMintParams(IERC20(token0), IERC20(token1), instructions.fee, instructions.tickLower, instructions.tickUpper, amount0, amount1, from, instructions.deadline, false, instructions.amountIn1, instructions.amountOut0Min, instructions.swapData1));
            } else if (instructions.swapTargetToken == token1) {
                require(amount0 >= instructions.amountIn0, "amountIn0>amount0");
                _swapAndMint(SwapAndMintParams(IERC20(token0), IERC20(token1), instructions.fee, instructions.tickLower, instructions.tickUpper, amount0, amount1, from, instructions.deadline, true, instructions.amountIn0, instructions.amountOut1Min, instructions.swapData0));
            } else {
                revert("invalid swap target");
            }
        } else if (instructions.whatToDo == WhatToDo.WITHDRAW_COLLECT_AND_SWAP) {
            require(liquidity >= instructions.liquidity, ">liquidity");
            _decreaseLiquidity(tokenId, instructions.liquidity, instructions.deadline);
            (uint amount0, uint amount1) = _collectAllFees(tokenId, IERC20(token0), IERC20(token1));
            uint targetAmount;
            if (token0 != instructions.swapTargetToken) {
                (uint amountInDelta, uint256 amountOutDelta) = _swap(IERC20(token0), IERC20(instructions.swapTargetToken), amount0, instructions.amountOut1Min, instructions.swapData0);
                if (amountInDelta < amount0) {
                    SafeERC20.safeTransfer(IERC20(token0), from, amount0 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount0; 
            }
            if (token1 != instructions.swapTargetToken) {
                (uint amountInDelta, uint256 amountOutDelta) = _swap(IERC20(token1), IERC20(instructions.swapTargetToken), amount1, instructions.amountOut0Min, instructions.swapData1);
                if (amountInDelta < amount1) {
                    SafeERC20.safeTransfer(IERC20(token1), from, amount1 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount1; 
            }

            uint toSend = _removeMaxProtocolFee(targetAmount);
            targetAmount = _removeProtocolFee(targetAmount, toSend);
            SafeERC20.safeTransfer(IERC20(instructions.swapTargetToken), from, toSend + targetAmount);
        } else if (instructions.whatToDo == WhatToDo.NOTHING) {
            // do nothing
        } else {
            revert("not supported whatToDo");
        }
        
        if (instructions.burnNoReturn) {
            _burn(tokenId); // if token still has liquidity this will revert
        } else {
            nonfungiblePositionManager.safeTransferFrom(address(this), from, tokenId, instructions.returnData);
        }

        return IERC721Receiver.onERC721Received.selector;
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
        bool swap0For1;
        uint amountIn;
        uint amountOutMin;
        bytes swapData;
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
        bool swap0For1;
        uint amountIn;
        uint amountOutMin;
        bytes swapData;
    }

    function swapAndIncreaseLiquidity(SwapAndIncreaseLiquidityParams calldata params) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        (, , address token0, address token1, , , , , , , , ) = nonfungiblePositionManager.positions(params.tokenId);
        _prepareAdd(IERC20(token0), IERC20(token1), params.amount0, params.amount1);
        (liquidity, amount0, amount1) = _swapAndIncrease(params, IERC20(token0), IERC20(token1));
    }

    // beneficiary may withdraw any token
    function withdrawProtocolFee(IERC20 token) external returns (uint balance) {
        require(msg.sender == protocolFeeBeneficiary, "!beneficiary");
        balance = token.balanceOf(address(this));
        token.transfer(protocolFeeBeneficiary, balance);
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
            require(balanceAfter - balanceBefore == amount0 - amountAdded0, "transfer error"); // reverts for fee-on-transfer tokens
        }
        if (amount1 > amountAdded1) {
            uint balanceBefore = token1.balanceOf(address(this));
            token1.transferFrom(msg.sender, address(this), amount1 - amountAdded1);
            uint balanceAfter = token1.balanceOf(address(this));
            require(balanceAfter - balanceBefore == amount1 - amountAdded1, "transfer error"); // reverts for fee-on-transfer tokens
        }
    }

    function _burn(uint tokenId) internal {
        nonfungiblePositionManager.burn(tokenId);
    }

    function _removeMaxProtocolFee(uint amount) internal view returns (uint) {
        uint maxFee = (amount * protocolFeeMantissa) / (BASE + protocolFeeMantissa);
        return amount - maxFee > 0 ? amount - maxFee - 1 : 0; // fee is rounded down - so need to remove 1 more
    }

    function _removeProtocolFee(uint amount, uint added) internal view returns (uint left) {
        uint fee = added * protocolFeeMantissa / BASE;
        left = amount - added - fee;
    }

    function _swapAndMint(SwapAndMintParams memory params) internal returns (uint tokenId, uint128 liquidity, uint added0, uint added1) {

        (uint total0, uint total1, uint available0, uint available1) = _swapAndPrepareAmounts(params);

        INonfungiblePositionManager.MintParams memory mintParams = 
            INonfungiblePositionManager.MintParams(
                address(params.token0), 
                address(params.token1), 
                params.fee, 
                params.tickLower, 
                params.tickUpper,
                available0,
                available1, 
                0,
                0,
                params.recipient,
                params.deadline
            );

        (tokenId,liquidity,added0,added1) = nonfungiblePositionManager.mint(mintParams);

        _returnLeftovers(params.token0, params.token1, total0, total1, added0, added1);
    }

    struct SwapAndIncreaseState  {
        uint total0;
        uint total1;
        uint available0;
        uint available1;
    }

    function _swapAndIncrease(SwapAndIncreaseLiquidityParams memory params, IERC20 token0, IERC20 token1) internal returns (uint128 liquidity, uint added0, uint added1) {

        SwapAndIncreaseState memory state;

        (state.total0, state.total1, state.available0, state.available1) = _swapAndPrepareAmounts(
            SwapAndMintParams(token0, token1, 0, 0, 0, params.amount0, params.amount1, msg.sender, params.deadline, params.swap0For1, params.amountIn, params.amountOutMin, params.swapData));
        
        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLiquidityParams = 
            INonfungiblePositionManager.IncreaseLiquidityParams(
                params.tokenId, 
                state.available0, 
                state.available1, 
                0, 
                0, 
                params.deadline
            );

        (liquidity, added0, added1) = nonfungiblePositionManager.increaseLiquidity(increaseLiquidityParams);

        _returnLeftovers(token0, token1, state.total0, state.total1, added0, added1);
    }

    // swaps available tokens and prepares max amounts to be added to nonfungiblePositionManager considering protocol fee
    function _swapAndPrepareAmounts(SwapAndMintParams memory params) internal returns (uint total0, uint total1, uint available0, uint available1) {
        if (params.swap0For1) { 
            require(params.amount0 >= params.amountIn, "amount0 < amountIn");
            (uint amountInDelta, uint256 amountOutDelta) = _swap(params.token0, params.token1, params.amountIn, params.amountOutMin, params.swapData);
            total0 = params.amount0 - amountInDelta;
            total1 = params.amount1 + amountOutDelta;
        } else {
            require(params.amount1 >= params.amountIn, "amount1 < amountIn");
            (uint amountInDelta, uint256 amountOutDelta) = _swap(params.token1, params.token0, params.amountIn, params.amountOutMin, params.swapData);
            total1 = params.amount1 - amountInDelta;
            total0 = params.amount0 + amountOutDelta;
        }

        available0 = _removeMaxProtocolFee(total0);
        available1 = _removeMaxProtocolFee(total1);

        params.token0.approve(address(nonfungiblePositionManager), available0);
        params.token1.approve(address(nonfungiblePositionManager), available1);
    }

    // returns leftover balances
    function _returnLeftovers(IERC20 token0, IERC20 token1, uint total0, uint total1, uint added0, uint added1) internal {

        // remove protocol fee from left balances - these fees will stay in the contract balance
        // and can be withdrawn at a later time from the beneficiary account
        uint left0 = _removeProtocolFee(total0, added0);
        uint left1 = _removeProtocolFee(total1, added1);

        // return leftovers
        if (left0 > 0) {
            SafeERC20.safeTransfer(token0, msg.sender, left0);
        }
        if (left1 > 0) {
            SafeERC20.safeTransfer(token1, msg.sender, left1);
        }
    }

    // general swap function which uses external router with off-chain calculated swap instructions
    // returns new token amounts after swap
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint amountIn, uint amountOutMin, bytes memory swapData) internal returns (uint amountInDelta, uint256 amountOutDelta) {
        if (amountIn > 0) {
            uint balanceInBefore = tokenIn.balanceOf(address(this));
            uint balanceOutBefore = tokenOut.balanceOf(address(this));

            // get router specific swap data
            bytes memory data = abi.decode(swapData, (bytes));

            // approve needed amount
            tokenIn.approve(swapRouter, amountIn);

            // execute swap
            (bool success,) = swapRouter.call(data);
            require(success, 'swap failed');

            // remove any remaining allowance
            tokenIn.approve(swapRouter, 0);

            uint balanceInAfter = tokenIn.balanceOf(address(this));
            uint balanceOutAfter = tokenOut.balanceOf(address(this));

            amountInDelta = balanceInBefore - balanceInAfter;
            amountOutDelta = balanceOutAfter - balanceOutBefore;

            // amountMin slippage check
            require(amountOutDelta >= amountOutMin, "<amountOutMin");
        }
    }

    function _decreaseLiquidity(uint tokenId, uint128 liquidity, uint deadline) internal {
        if (liquidity > 0) {
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
    }

    function _collectAllFees(uint tokenId, IERC20 token0, IERC20 token1) internal returns (uint256 amount0, uint256 amount1) {
        uint balanceBefore0 = token0.balanceOf(address(this));
        uint balanceBefore1 = token1.balanceOf(address(this));
        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)
        );
        uint balanceAfter0 = token0.balanceOf(address(this));
        uint balanceAfter1 = token1.balanceOf(address(this));
        require(balanceAfter0 - balanceBefore0 == amount0, "collect error token 0"); // reverts for fee-on-transfer tokens
        require(balanceAfter1 - balanceBefore1 == amount1, "collect error token 1"); // reverts for fee-on-transfer tokens
    }
}