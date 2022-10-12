// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./external/openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "./external/openzeppelin/token/ERC721/IERC721Receiver.sol";

import "./external/polygon/IRootChainManager.sol";
import "./external/optimism/IL1StandardBridge.sol";

import "./external/IWETH.sol";


error Unauthorized();
error WrongChain();
error SameToken();
error MissingBridge();
error MissingBridgeToken();
error SwapFailed();
error AmountError();
error SlippageError();
error CollectError();
error TransferError();
error EtherSendFailed();
error TooMuchEtherSent();
error NoEtherToken();
error NotEnoughLiquidity();

contract V3Utils is IERC721Receiver {

    uint256 constant private BASE = 1e18;
 
    IWETH immutable public weth; // wrapped native token address
    INonfungiblePositionManager immutable public nonfungiblePositionManager; // uniswap v3 position manager
    address swapRouter; // the trusted contract which is allowed to do arbitrary (swap) calls - 0x for now

    uint256 immutable public protocolFeeMantissa; // the fee as a mantissa (scaled by BASE)
    address immutable public protocolFeeBeneficiary; // address recieving the protocol fee

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
        COMPOUND_FEES,
        BRIDGE_TO_POLYGON,
        BRIDGE_TO_OPTIMISM
    }

    struct Instructions {
        WhatToDo whatToDo;

        // target token for swaps
        address swapTargetToken;

        // if token0 needs to be swapped to target - set values - if input amount can not be decided beforehand (for swaps which depend on decreaseLiquidity) - decrease this value by some percents to prevent reverts
        uint amountIn0;
        uint amountOut0Min;
        bytes swapData0;

        // if token1 needs to be swapped to target - set values - if input amount can not be decided beforehand (for swaps which depend on decreaseLiquidity) - decrease this value by some percents to prevent reverts
        uint amountIn1;
        uint amountOut1Min;
        bytes swapData1;

        // for creating new positions
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        bool burnNoReturn;
        
        // for liquidity operations
        uint128 liquidity;
        uint deadline;

        // for polygon - address bridge
        // for optimism - address bridge0, address token0, address bridge1, address token1
        bytes bridgeData; 

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

    function onERC721Received(address , address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        Instructions memory instructions = abi.decode(data, (Instructions));
        ERC721ReceivedState memory state;

        (,,state.token0,state.token1,,,,state.liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);

        if (instructions.whatToDo == WhatToDo.COMPOUND_FEES) {
            (state.amount0, state.amount1) = _collectAllFees(tokenId, IERC20(state.token0), IERC20(state.token1));

            if (instructions.swapTargetToken == state.token0) {
                if (state.amount1 < instructions.amountIn1) {
                    revert AmountError();
                }
                _swapAndIncrease(SwapAndIncreaseLiquidityParams(tokenId, state.amount0, state.amount1, from, instructions.deadline, IERC20(state.token1), instructions.amountIn1, instructions.amountOut1Min, instructions.swapData1, 0, 0, ""), IERC20(state.token0), IERC20(state.token1));
            } else if (instructions.swapTargetToken == state.token1) {
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

            if (instructions.swapTargetToken == state.token0) {
                if (state.amount1 < instructions.amountIn1) {
                    revert AmountError();
                }
                _swapAndMint(SwapAndMintParams(IERC20(state.token0), IERC20(state.token1), instructions.fee, instructions.tickLower, instructions.tickUpper, state.amount0, state.amount1, from, instructions.deadline, IERC20(state.token1), instructions.amountIn1, instructions.amountOut1Min, instructions.swapData1, 0, 0, ""));
            } else if (instructions.swapTargetToken == state.token1) {
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
            if (state.token0 != instructions.swapTargetToken) {
                (uint amountInDelta, uint256 amountOutDelta) = _swap(IERC20(state.token0), IERC20(instructions.swapTargetToken), state.amount0, instructions.amountOut0Min, instructions.swapData0);
                if (amountInDelta < state.amount0) {
                    SafeERC20.safeTransfer(IERC20(state.token0), from, state.amount0 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += state.amount0; 
            }
            if (state.token1 != instructions.swapTargetToken) {
                (uint amountInDelta, uint256 amountOutDelta) = _swap(IERC20(state.token1), IERC20(instructions.swapTargetToken), state.amount1, instructions.amountOut1Min, instructions.swapData1);
                if (amountInDelta < state.amount1) {
                    SafeERC20.safeTransfer(IERC20(state.token1), from, state.amount1 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += state.amount1; 
            }

            uint toSend = _removeMaxProtocolFee(targetAmount);

            // calculate amount left
            uint left = _removeProtocolFee(targetAmount, toSend);

            SafeERC20.safeTransfer(IERC20(instructions.swapTargetToken), from, toSend + left);
        } else if (instructions.whatToDo == WhatToDo.BRIDGE_TO_OPTIMISM || instructions.whatToDo == WhatToDo.BRIDGE_TO_POLYGON) {
            _decreaseLiquidity(tokenId, state.liquidity, instructions.deadline);
            (state.amount0, state.amount1) = _collectAllFees(tokenId, IERC20(state.token0), IERC20(state.token1));

            if (instructions.whatToDo == WhatToDo.BRIDGE_TO_OPTIMISM) {
                (address bridge0, address token0L2, address bridge1, address token1L2) = abi.decode(instructions.bridgeData, (address, address, address, address));
                if (state.amount0 > 0) {
                    _bridgeToOptimism(bridge0, from, state.token0, token0L2, state.amount0);
                }
                if (state.amount1 > 0) {
                    _bridgeToOptimism(bridge1, from, state.token1, token1L2, state.amount1);
                }
            } else {
                address bridge = abi.decode(instructions.bridgeData, (address));
                if (state.amount0 > 0) {
                    _bridgeToPolygon(bridge, from, state.token0, state.amount0);
                }
                if (state.amount1 > 0) {
                    _bridgeToPolygon(bridge, from, state.token1, state.amount1);
                }
            }
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

    struct SwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient; // recipient of tokenOut and leftover tokenIn
        bytes swapData;
        bool unwrap; // if tokenIn or tokenOut is WETH - unwrap
    }

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
                SafeERC20.safeTransfer(params.tokenOut, params.recipient, amountOut);
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
                SafeERC20.safeTransfer(params.tokenIn, params.recipient, leftOver);
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

        // source token for swaps (maybe either token0, token1 or another token)
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
        
        // target token for swaps (maybe either token0, token1 or another token)
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

    function swapAndIncreaseLiquidity(SwapAndIncreaseLiquidityParams calldata params) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        (, , address token0, address token1, , , , , , , , ) = nonfungiblePositionManager.positions(params.tokenId);
        _prepareAdd(IERC20(token0), IERC20(token1), params.swapSourceToken, params.amount0, params.amount1, params.amountIn0 + params.amountIn1);
        (liquidity, amount0, amount1) = _swapAndIncrease(params, IERC20(token0), IERC20(token1));
    }

    // beneficiary may withdraw any token
    function withdrawProtocolFee(IERC20 token) external returns (uint balance) {
        if (msg.sender != protocolFeeBeneficiary) {
            revert Unauthorized();
        }
        balance = token.balanceOf(address(this));
        token.transfer(protocolFeeBeneficiary, balance);
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
            token0.transferFrom(msg.sender, address(this), amount0 - amountAdded0);
            uint balanceAfter = token0.balanceOf(address(this));
            if (balanceAfter - balanceBefore != amount0 - amountAdded0) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (amount1 > amountAdded1) {
            uint balanceBefore = token1.balanceOf(address(this));
            token1.transferFrom(msg.sender, address(this), amount1 - amountAdded1);
            uint balanceAfter = token1.balanceOf(address(this));
            if (balanceAfter - balanceBefore != amount1 - amountAdded1) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (token0 != otherToken && token1 != otherToken && address(otherToken) != address(0) && amountOther > amountAddedOther) {
            uint balanceBefore = otherToken.balanceOf(address(this));
            otherToken.transferFrom(msg.sender, address(this), amountOther - amountAddedOther);
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

    function _bridgeToPolygon(address bridge, address to, address tokenL1, uint amount) internal {

        if (block.chainid != 1) {
            revert WrongChain();
        }

        if (bridge != address(0)) {
            IRootChainManager manager = IRootChainManager(bridge);
            uint bridgeAmount = _removeMaxProtocolFee(amount);
            if (tokenL1 == address(weth)) {
                weth.withdraw(bridgeAmount);
                manager.depositEtherFor{value: bridgeAmount}(to);
            } else {
                bytes32 t = manager.tokenToType(tokenL1);
                address predicate = manager.typeToPredicate(t);
                
                if (predicate != address(0)) {
                    IERC20(tokenL1).approve(predicate, bridgeAmount);
                    IRootChainManager(bridge).depositFor(to, tokenL1, abi.encode(bridgeAmount));
                } else {
                    revert MissingBridgeToken();
                } 
            }
        } else {
            revert MissingBridge();
        }
    }

    // must check token list for bridging parameters https://github.com/ethereum-optimism/ethereum-optimism.github.io/blob/master/optimism.tokenlist.json
    function _bridgeToOptimism(address bridge, address to, address tokenL1, address tokenL2, uint amount) internal {

        if (block.chainid != 1) {
            revert WrongChain();
        }

        if (bridge != address(0)) {
            uint bridgeAmount = _removeMaxProtocolFee(amount);
            if (tokenL1 == address(weth)) {
                weth.withdraw(bridgeAmount);
                IL1StandardBridge(bridge).depositETHTo{value: bridgeAmount}(to, 200_000, ""); // free gas: until 1.92 million - more than enough
            } else {
                if (tokenL2 != address(0)) {
                    IERC20(tokenL1).approve(bridge, bridgeAmount);
                    IL1StandardBridge(bridge).depositERC20To(address(tokenL1), tokenL2, to, bridgeAmount, 200_000, ""); // free gas: until 1.92 million - more than enough
                } else {
                    revert MissingBridgeToken();
                }
            }
        } else {
            revert MissingBridge();
        }
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
                SafeERC20.safeTransfer(params.swapSourceToken, params.recipient, leftOver);
            }
        } else {
            total0 = params.amount0;
            total1 = params.amount1;
        }

        available0 = _removeMaxProtocolFee(total0);
        available1 = _removeMaxProtocolFee(total1);

        params.token0.approve(address(nonfungiblePositionManager), available0);
        params.token1.approve(address(nonfungiblePositionManager), available1);
    }

    // returns leftover balances
    function _returnLeftovers(address to, IERC20 token0, IERC20 token1, uint total0, uint total1, uint added0, uint added1) internal {

        // remove protocol fee from left balances - these fees will stay in the contract balance
        // and can be withdrawn at a later time from the beneficiary account
        uint left0 = _removeProtocolFee(total0, added0);
        uint left1 = _removeProtocolFee(total1, added1);

        // return leftovers
        if (left0 > 0) {
            SafeERC20.safeTransfer(token0, to, left0);
        }
        if (left1 > 0) {
            SafeERC20.safeTransfer(token1, to, left1);
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
            if (!success) {
                revert SwapFailed();
            }

            // remove any remaining allowance
            tokenIn.approve(swapRouter, 0);

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

    // for WETH unwrapping
    receive() external payable {}
}