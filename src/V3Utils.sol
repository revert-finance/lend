// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "./external/IWETH.sol";

contract V3Utils is IERC721Receiver {

    using SafeERC20 for IERC20;

    uint256 constant private BASE = 1e18;
 
    IWETH immutable public weth; // wrapped native token address
    INonfungiblePositionManager immutable public nonfungiblePositionManager; // uniswap v3 position manager
    address immutable swapRouter; // the trusted contract which is allowed to do arbitrary (swap) calls - 0x for now

    uint256 immutable public protocolFeeMantissa; // the fee as a mantissa (scaled by BASE)
    address immutable public protocolFeeBeneficiary; // address being able to withdraw accumulated protocol fee

    constructor(IWETH _weth, INonfungiblePositionManager _nonfungiblePositionManager, address _swapRouter, uint256 _protocolFeeMantissa, address _beneficiary) {
        weth = _weth;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
        protocolFeeMantissa = _protocolFeeMantissa;
        protocolFeeBeneficiary = _beneficiary;
    }

    enum WhatToDo {
        CHANGE_RANGE,
        WITHDRAW_COLLECT_AND_SWAP,
        COMPOUND_FEES
    }

    struct Instructions {
        // what action to perform on provided Uniswap v3 position
        WhatToDo whatToDo;

        // target token for swaps
        address targetToken;

        // if token0 needs to be swapped to targetToken - set values
        // if amountIn0 can not be decided beforehand (for swaps which depend on decreaseLiquidity) - decrease this value by some percents to prevent reverts
        uint amountIn0;
        uint amountOut0Min;
        bytes swapData0;

        // if token1 needs to be swapped to targetToken - set values
        // if amountIn1 can not be decided beforehand (for swaps which depend on decreaseLiquidity) - decrease this value by some percents to prevent reverts
        uint amountIn1;
        uint amountOut1Min;
        bytes swapData1;

        // for creating new positions (change range)
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        
        // for liquidity operations
        uint128 liquidity;
        uint deadline;

        // data sent when token returned (optional)
        bytes returnData;
    }

    struct ERC721ReceivedState {
        address token0;
        address token1;
        uint128 liquidity;
        uint amount0;
        uint amount1;
    }

    /**
     * @dev Method which recieves Uniswap v3 NFT and does manipulation as configured in encoded Instructions parameter
     * At the end the NFT and any leftover tokens are returned to sender.
     */
    function onERC721Received(address , address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        // only Uniswap v3 NFTs allowed
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }

        Instructions memory instructions = abi.decode(data, (Instructions));
        ERC721ReceivedState memory state;

        (,,state.token0,state.token1,,,,state.liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);

        if (instructions.whatToDo == WhatToDo.COMPOUND_FEES) {
            (state.amount0, state.amount1) = _collectAllFees(tokenId, IERC20(state.token0), IERC20(state.token1));

            if (instructions.targetToken == state.token0) {
                if (state.amount1 < instructions.amountIn1) {
                    revert AmountError();
                }
                _swapAndIncrease(SwapAndIncreaseLiquidityParams(tokenId, state.amount0, state.amount1, from, instructions.deadline, IERC20(state.token1), instructions.amountIn1, instructions.amountOut1Min, instructions.swapData1, 0, 0, ""), IERC20(state.token0), IERC20(state.token1));
            } else if (instructions.targetToken == state.token1) {
                if (state.amount0 < instructions.amountIn0) {
                    revert AmountError();
                }
                _swapAndIncrease(SwapAndIncreaseLiquidityParams(tokenId, state.amount0, state.amount1, from, instructions.deadline, IERC20(state.token0), 0, 0, "", instructions.amountIn0, instructions.amountOut0Min, instructions.swapData0), IERC20(state.token0), IERC20(state.token1));
            } else {
                _swapAndIncrease(SwapAndIncreaseLiquidityParams(tokenId, state.amount0, state.amount1, from, instructions.deadline, IERC20(address(0)), 0, 0, "", 0, 0, ""), IERC20(state.token0), IERC20(state.token1));
            }
        } else if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {
            _decreaseLiquidity(tokenId, state.liquidity, instructions.deadline);
            (state.amount0, state.amount1) = _collectAllFees(tokenId, IERC20(state.token0), IERC20(state.token1));

            if (instructions.targetToken == state.token0) {
                if (state.amount1 < instructions.amountIn1) {
                    revert AmountError();
                }
                _swapAndMint(SwapAndMintParams(IERC20(state.token0), IERC20(state.token1), instructions.fee, instructions.tickLower, instructions.tickUpper, state.amount0, state.amount1, from, instructions.deadline, IERC20(state.token1), instructions.amountIn1, instructions.amountOut1Min, instructions.swapData1, 0, 0, ""));
            } else if (instructions.targetToken == state.token1) {
                if (state.amount0 < instructions.amountIn0) {
                    revert AmountError();
                }
                _swapAndMint(SwapAndMintParams(IERC20(state.token0), IERC20(state.token1), instructions.fee, instructions.tickLower, instructions.tickUpper, state.amount0, state.amount1, from, instructions.deadline, IERC20(state.token0), 0, 0, "", instructions.amountIn0, instructions.amountOut0Min, instructions.swapData0));
            } else {
                _swapAndMint(SwapAndMintParams(IERC20(state.token0), IERC20(state.token1), instructions.fee, instructions.tickLower, instructions.tickUpper, state.amount0, state.amount1, from, instructions.deadline, IERC20(state.token0), 0, 0, "", 0, 0, ""));
            }
        } else if (instructions.whatToDo == WhatToDo.WITHDRAW_COLLECT_AND_SWAP) {
            if (state.liquidity < instructions.liquidity) {
                revert NotEnoughLiquidity();
            }
            _decreaseLiquidity(tokenId, instructions.liquidity, instructions.deadline);
            (state.amount0, state.amount1) = _collectAllFees(tokenId, IERC20(state.token0), IERC20(state.token1));

            uint targetAmount;
            if (state.token0 != instructions.targetToken) {
                (uint amountInDelta, uint256 amountOutDelta) = _swap(IERC20(state.token0), IERC20(instructions.targetToken), state.amount0, instructions.amountOut0Min, instructions.swapData0);
                if (amountInDelta < state.amount0) {
                    IERC20(state.token0).safeTransfer(from, state.amount0 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += state.amount0; 
            }
            if (state.token1 != instructions.targetToken) {
                (uint amountInDelta, uint256 amountOutDelta) = _swap(IERC20(state.token1), IERC20(instructions.targetToken), state.amount1, instructions.amountOut1Min, instructions.swapData1);
                if (amountInDelta < state.amount1) {
                    IERC20(state.token1).safeTransfer(from, state.amount1 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += state.amount1; 
            }

            uint toSend = _removeMaxProtocolFee(targetAmount);

            // calculate amount left
            uint left = _removeProtocolFee(targetAmount, toSend);

            IERC20(instructions.targetToken).safeTransfer(from, toSend + left);
        } else {
            revert NotSupportedWhatToDo();
        }
        
        // return token to owner (this line guarantees that token is returned to rightful owner)
        nonfungiblePositionManager.safeTransferFrom(address(this), from, tokenId, instructions.returnData);

        return IERC721Receiver.onERC721Received.selector;
    }

    struct SwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient; // recipient of tokenOut and leftover tokenIn (if any leftover)
        bytes swapData;
        bool unwrap; // if tokenIn or tokenOut is WETH - unwrap
    }

    /**
     * @dev Swaps amountIn of tokenIn for tokenOut - returning at least minAmountOut
     * If tokenIn is wrapped native token - both the token or the wrapped token can be sent (the sum of both must be equal to amountIn)
     * Optionally unwraps any wrapped native token and returns native token instead
     */
    function swap(SwapParams calldata params) external payable returns (uint256 amountOut) {

        _prepareAdd(params.tokenIn, IERC20(address(0)), IERC20(address(0)), params.amountIn, 0, 0);

        (uint amountInDelta, uint256 amountOutDelta) = _swap(params.tokenIn, params.tokenOut, params.amountIn, params.minAmountOut, params.swapData);

        amountOut = _removeMaxProtocolFee(amountOutDelta);

        // send swapped amount minus fees of tokenOut
        if (amountOut > 0) {
            if (address(params.tokenOut) == address(weth) && params.unwrap) {
                weth.withdraw(amountOut);
                (bool sent, ) = params.recipient.call{value: amountOut}("");
                if (!sent) {
                    revert EtherSendFailed();
                }
            } else {
                params.tokenOut.safeTransfer(params.recipient, amountOut);
            }
        }

        // if not all was swapped - return leftovers of tokenIn
        uint leftOver = params.amountIn - amountInDelta;
        if (leftOver > 0) {
            if (address(params.tokenIn) == address(weth) && params.unwrap) { 
                weth.withdraw(leftOver);
                (bool sent, ) = params.recipient.call{value: leftOver}("");
                if (!sent) {
                    revert EtherSendFailed();
                }
            } else {
                params.tokenIn.safeTransfer(params.recipient, leftOver);
            }
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
        address recipient; // recipient of nft and leftover tokens
        uint256 deadline;

        // source token for swaps (maybe either address(0), token0, token1 or another token)
        IERC20 swapSourceToken;

        // if swapSourceToken needs to be swapped to token0 - set values
        uint amountIn0;
        uint amountOut0Min;
        bytes swapData0;

        // if swapSourceToken needs to be swapped to token1 - set values
        uint amountIn1;
        uint amountOut1Min;
        bytes swapData1;
    }

    /**
     * @dev Does 1 or 2 swaps from swapSourceToken to token0 and token1 and adds as much as possible liquidity to a newly minted position.
     * Sends newly minted position and any leftover tokens to recipient.
     */
    function swapAndMint(SwapAndMintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (params.token0 == params.token1) {
            revert SameToken();
        }

        _prepareAdd(params.token0, params.token1, params.swapSourceToken, params.amount0, params.amount1, params.amountIn0 + params.amountIn1);
        (tokenId, liquidity, amount0, amount1) = _swapAndMint(params);
    }

    struct SwapAndIncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0;
        uint256 amount1;
        address recipient; // recipient of leftover tokens
        uint256 deadline;
        
        // source token for swaps (maybe either address(0), token0, token1 or another token)
        IERC20 swapSourceToken;

        // if swapSourceToken needs to be swapped to token0 - set values
        uint amountIn0;
        uint amountOut0Min;
        bytes swapData0;

        // if swapSourceToken needs to be swapped to token1 - set values
        uint amountIn1;
        uint amountOut1Min;
        bytes swapData1;
    }

    /**
     * @dev Does 1 or 2 swaps from swapSourceToken to token0 and token1 and adds as much as possible liquidity to any existing position (no need to be position owner).
     * Sends any leftover tokens to recipient.
     */
    function swapAndIncreaseLiquidity(SwapAndIncreaseLiquidityParams calldata params) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        (, , address token0, address token1, , , , , , , , ) = nonfungiblePositionManager.positions(params.tokenId);
        _prepareAdd(IERC20(token0), IERC20(token1), params.swapSourceToken, params.amount0, params.amount1, params.amountIn0 + params.amountIn1);
        (liquidity, amount0, amount1) = _swapAndIncrease(params, IERC20(token0), IERC20(token1));
    }

    /**
     * @dev Withdraw tokens left in contract (collected protocol fees) - only callable by protocolFeeBeneficiary
     */
    function withdrawProtocolFee(IERC20 token) external returns (uint balance) {
        if (msg.sender != protocolFeeBeneficiary) {
            revert Unauthorized();
        }
        balance = token.balanceOf(address(this));
        token.safeTransfer(protocolFeeBeneficiary, balance);
    }

    // checks if required amounts are provided and are exact - wraps any provided ETH as WETH
    // if less or more provided reverts
    function _prepareAdd(IERC20 token0, IERC20 token1, IERC20 otherToken, uint amount0, uint amount1, uint amountOther) internal
    {
        uint amountAdded0;
        uint amountAdded1;
        uint amountAddedOther;

        // wrap ether sent
        if (msg.value > 0) {
            weth.deposit{ value: msg.value }();

            if (address(weth) == address(token0)) {
                amountAdded0 = msg.value;
                if (amountAdded0 > amount0) {
                    revert TooMuchEtherSent();
                }
            } else if (address(weth) == address(token1)) {
                amountAdded1 = msg.value;
                if (amountAdded1 > amount1) {
                    revert TooMuchEtherSent();
                }
            } else if (address(weth) == address(otherToken)) {
                amountAddedOther = msg.value;
                if (amountAddedOther > amountOther) {
                    revert TooMuchEtherSent();
                }
            } else {
                revert NoEtherToken();
            }
        }

        // get missing tokens (fails if not enough provided)
        if (amount0 > amountAdded0) {
            uint balanceBefore = token0.balanceOf(address(this));
            token0.safeTransferFrom(msg.sender, address(this), amount0 - amountAdded0);
            uint balanceAfter = token0.balanceOf(address(this));
            if (balanceAfter - balanceBefore != amount0 - amountAdded0) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (amount1 > amountAdded1) {
            uint balanceBefore = token1.balanceOf(address(this));
            token1.safeTransferFrom(msg.sender, address(this), amount1 - amountAdded1);
            uint balanceAfter = token1.balanceOf(address(this));
            if (balanceAfter - balanceBefore != amount1 - amountAdded1) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (token0 != otherToken && token1 != otherToken && address(otherToken) != address(0) && amountOther > amountAddedOther) {
            uint balanceBefore = otherToken.balanceOf(address(this));
            otherToken.safeTransferFrom(msg.sender, address(this), amountOther - amountAddedOther);
            uint balanceAfter = otherToken.balanceOf(address(this));
            if (balanceAfter - balanceBefore != amountOther - amountAddedOther) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
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

        _returnLeftovers(params.recipient, params.token0, params.token1, total0, total1, added0, added1);
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
            SwapAndMintParams(token0, token1, 0, 0, 0, params.amount0, params.amount1, params.recipient, params.deadline, params.swapSourceToken, params.amountIn0, params.amountOut0Min, params.swapData0, params.amountIn1, params.amountOut1Min, params.swapData1));

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

        _returnLeftovers(params.recipient, token0, token1, state.total0, state.total1, added0, added1);
    }

    // swaps available tokens and prepares max amounts to be added to nonfungiblePositionManager considering protocol fee
    function _swapAndPrepareAmounts(SwapAndMintParams memory params) internal returns (uint total0, uint total1, uint available0, uint available1) {
        if (params.swapSourceToken == params.token0) { 
            if (params.amount0 < params.amountIn1) {
                revert AmountError();
            }
            (uint amountInDelta, uint256 amountOutDelta) = _swap(params.token0, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1);
            total0 = params.amount0 - amountInDelta;
            total1 = params.amount1 + amountOutDelta;
        } else if (params.swapSourceToken == params.token1) { 
            if (params.amount1 < params.amountIn0) {
                revert AmountError();
            }
            (uint amountInDelta, uint256 amountOutDelta) = _swap(params.token1, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0);
            total1 = params.amount1 - amountInDelta;
            total0 = params.amount0 + amountOutDelta;
        } else if (address(params.swapSourceToken) != address(0)) {

            (uint amountInDelta0, uint256 amountOutDelta0) = _swap(params.swapSourceToken, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0);
            (uint amountInDelta1, uint256 amountOutDelta1) = _swap(params.swapSourceToken, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1);
            total0 = params.amount0 + amountOutDelta0;
            total1 = params.amount1 + amountOutDelta1;

            // return third token leftover if any
            uint leftOver = params.amountIn0 + params.amountIn1 - amountInDelta0 - amountInDelta1;

            if (leftOver > 0) {
                params.swapSourceToken.safeTransfer(params.recipient, leftOver);
            }
        } else {
            total0 = params.amount0;
            total1 = params.amount1;
        }

        available0 = _removeMaxProtocolFee(total0);
        available1 = _removeMaxProtocolFee(total1);

        if (available0 > 0) {
            params.token0.approve(address(nonfungiblePositionManager), available0);
        }
        if (available1 > 0) {
            params.token1.approve(address(nonfungiblePositionManager), available1);
        }
    }

    // returns leftover balances
    function _returnLeftovers(address to, IERC20 token0, IERC20 token1, uint total0, uint total1, uint added0, uint added1) internal {

        // remove protocol fee from left balances - these fees will stay in the contract balance
        // and can be withdrawn at a later time from the beneficiary account
        uint left0 = _removeProtocolFee(total0, added0);
        uint left1 = _removeProtocolFee(total1, added1);

        // return leftovers
        if (left0 > 0) {
            token0.safeTransfer(to, left0);
        }
        if (left1 > 0) {
            token1.safeTransfer(to, left1);
        }
    }

    // general swap function which uses external router with off-chain calculated swap instructions
    // does slippage check with amountOutMin param
    // returns new token amounts after swap
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint amountIn, uint amountOutMin, bytes memory swapData) internal returns (uint amountInDelta, uint256 amountOutDelta) {
        if (amountIn > 0) {
            uint balanceInBefore = tokenIn.balanceOf(address(this));
            uint balanceOutBefore = tokenOut.balanceOf(address(this));

            // get router specific swap data
            (address allowanceTarget, bytes memory data) = abi.decode(swapData, (address, bytes));

            // approve needed amount
            tokenIn.approve(allowanceTarget, amountIn);

            // execute swap
            (bool success,) = swapRouter.call(data);
            if (!success) {
                revert SwapFailed();
            }

            // remove any remaining allowance
            tokenIn.approve(allowanceTarget, 0);

            uint balanceInAfter = tokenIn.balanceOf(address(this));
            uint balanceOutAfter = tokenOut.balanceOf(address(this));

            amountInDelta = balanceInBefore - balanceInAfter;
            amountOutDelta = balanceOutAfter - balanceOutBefore;

            // amountMin slippage check
            if (amountOutDelta < amountOutMin) {
                revert SlippageError();
            }
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

        // reverts for fee-on-transfer tokens
        if (balanceAfter0 - balanceBefore0 != amount0) {
            revert CollectError();
        }
        if (balanceAfter1 - balanceBefore1 != amount1) {
            revert CollectError();
        }
    }

    // needed for WETH unwrapping
    receive() external payable {}
}

// error types
error Unauthorized();
error WrongContract();
error WrongChain();
error NotSupportedWhatToDo();
error SameToken();
error SwapFailed();
error AmountError();
error SlippageError();
error CollectError();
error TransferError();
error EtherSendFailed();
error TooMuchEtherSent();
error NoEtherToken();
error NotEnoughLiquidity();