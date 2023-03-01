// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./V3Utils.sol";

/// @title RangeAdjustor
/// @notice Allows operator of RangeAdjustor contract (Revert controlled bot) to change range for configured positions
/// Positions need to be approved for the contract and configured with setConfig method
contract RangeAdjustor is Ownable {

    error Unauthorized();
    error WrongContract();
    error InvalidConfig();
    error NotSupportedFeeTier();
    error AdjustStateError();
    error NotConfigured();

    event PositionConfigured(uint256 indexed tokenId);
    event RangeChanged(uint256 indexed oldTokenId, uint256 indexed newTokenId);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);

    uint256 private constant Q64 = 2**64; 
    uint256 private constant Q96 = 2**96; 

    V3Utils public immutable v3Utils;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;

    // to store current token id while doing adjust()
    uint256 private currentTokenId;

    // operator
    address public operator;

    struct PositionConfig {
        int24 lowerTickLimit; // if negative also in-range positions may be adjusted
        int24 upperTickLimit; // if negative also in-range positions may be adjusted

        int24 lowerTickDelta; // must be 0 or a negative multiple of tick spacing
        int24 upperTickDelta; // must greater than 0 and positive multiple of tick spacing

        int64 maxSlippageX64; // max allowed swap slippage including fees, price impact and slippage - from current pool price (to be sure revert bot can not do silly things)
        int64 maxGasFeeRewardX64; // max allowed token percentage to be available for covering gas cost of operator (operator chooses which one of the two tokens to receive)
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public configs;

    constructor(V3Utils _v3Utils, address _swapRouter, address _operator)  {
        v3Utils = _v3Utils;
        INonfungiblePositionManager npm = _v3Utils.nonfungiblePositionManager();
        nonfungiblePositionManager = npm;
        factory = IUniswapV3Factory(npm.factory());
        operator = _operator;
        emit OperatorChanged(address(0), _operator);
    }

    /**
     * @notice Admin function to change operator address
     */
    function changeOperator(address _operator) onlyOwner external {
        emit OperatorChanged(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Sets config for a given NFT - must be owner
     */
    function setConfig(uint256 tokenId, PositionConfig calldata config) external {

        if (config.lowerTickDelta > 0 || config.upperTickDelta <= 0) {
            revert InvalidConfig();
        }

        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }
        configs[tokenId] = config;

        emit PositionConfigured(tokenId);
    }

    struct AdjustParams {
        uint256 tokenId;
        bool swap0To1;
        uint256 amountIn; // if this is set to 0 no swap happens
        bytes swapData;
        uint256 deadline; // for uniswap operations
        bool takeFeeFrom0;
        uint256 feeAmount;
    }

    /**
     * @notice Adjust token (must be in correct state)
     * Can be called only from configured operator account
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function adjust(AdjustParams calldata params) external {
        // if already in an adjustment - do not allow reentrancy
        if (currentTokenId != 0) {
            revert AdjustStateError();
        }

        if (msg.sender != operator) {
            revert Unauthorized();
        }

        PositionConfig storage config = configs[params.tokenId];
        if (config.upperTickDelta == 0) {
            revert NotConfigured();
        }

        // check if in valid range for move range
        (,,address token0,address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = nonfungiblePositionManager.positions(params.tokenId);

        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = pool.slot0();
        if (currentTick < tickLower - config.lowerTickLimit || currentTick >= tickUpper + config.upperTickLimit) {

            // calculate with current pool price 
            uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
            uint256 minAmountOut = FullMath.mul(Q64 - maxSlippageX64, params.swap0To1 ? FullMath.mulDiv(params.amountIn, priceX96, Q96) : FullMath.mulDiv(params.amountIn, Q96, priceX96), Q64);
            uint24 tickSpacing = _getTickSpacing(fee);

            address owner = nonfungiblePositionManager.ownerOf(tokenId);

            // before starting process - set context id
            currentTokenId = params.tokenId;

            // change range with v3utils
            bytes memory data = abi.encode(V3Utils.Instructions(
                V3Utils.WhatToDo.CHANGE_RANGE,
                params.swap0To1 ? token1 : token0,
                params.swap0To1 ? params.amountIn : 0,
                params.swap0To1 ? minAmountOut : 0,
                params.swap0To1 ? params.swapData : "",
                params.swap0To1 ? 0 : params.amountIn,
                params.swap0To1 ? 0 : minAmountOut,
                params.swap0To1 ? "" : params.swapData,
                type(uint128).max,
                type(uint128).max,
                fee,
                currentTick - (currentTick % tickSpacing) + config.lowerTickDelta,
                currentTick - (currentTick % tickSpacing) + config.upperTickDelta,
                liquidity,
                0,
                0,
                deadline,
                address(this), // receive leftover tokens to grab fees - and then return rest to owner
                address(this), // recieve the new NFT to register config and then resend
                false,
                "",
                abi.encode(owner, params.takeFeeFrom0, params.feeAmount, sqrtPriceX96) // pass needed parameters to onERC721Received
            ));
            nonfungiblePositionManager.safeTransferFrom(owner, address(v3Utils), params.tokenId, data);

            // after everything is finished - reset this to 0
            currentTokenId = 0;
        }
    }

    // recieve new ERC-721 just to resend to original owner - and update config
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        // only Uniswap v3 NFTs allowed
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }

        // only minted NFTs from V3Utils are allowed
        if (from != address(v3Utils) || operator != address(v3Utils)) {
            revert WrongContract();
        }

        // get previous token id from contract state
        uint256 previousTokenId = currentTokenId;
        if (previousTokenId == 0) {
            revert AdjustStateError();
        }

        // get context variables forwarded through data
        (address owner, bool takeFeeFrom0, uint256 feeAmount, uint160 sqrtPriceX96) = abi.decode(data, (address, bool, uint256, uint160));
       
        // copy token config for new token
        configs[tokenId] = configs[previousTokenId];

        // delete config for old position
        delete configs[previousTokenId];

        emit PositionConfigured(tokenId);

        // forwards to real owner - forwarding data
        nonfungiblePositionManager.safeTransferFrom(address(this), owner, tokenId, "");

        // balances (leftover tokens from change range operation)
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // check amount of leftover tokens - grab fee - return rest
        (,,address token0,address token1,, int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);

        // position value (position has no fees it has been just created - so only liquidity)
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity);

        // max fee in feeToken
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        uint256 totalFeeTokenAmount = takeFeeFrom0 ? balance0 + amount0 + FullMath.mulDiv(balance1 + amount1, priceX96, Q96) : balance1 + amount1 + FullMath.mulDiv(balance0 + amount0, Q96, priceX96);

        // calculate max permited fee amount for this position
        uint256 maxFeeAmount = FullMath.mulDiv(totalFeeTokenAmount, configs[previousTokenId].maxFeeAmount, Q64);

        // calculate fee amount which can be sent.. it can be less.. so it is the operators duty to do correct swap
        uint256 effectiveFeeAmount = (feeAmount > (takeFeeFrom0 ? balance0 : balance1) ? (takeFeeFrom0 ? balance0 : balance1) : feeAmount);
        if (effectiveFeeAmount > maxFeeAmount) {
            effectiveFeeAmount = maxFeeAmount;
        }

        // send fee to operator
        if (effectiveFeeAmount > 0) {
            IERC20(takeFeeFrom0 ? token0 : token1).transfer(operator, effectiveFeeAmount);
            if (takeFeeFrom0) {
                balance0 -= effectiveFeeAmount;
            } else {
                balance1 -= effectiveFeeAmount;
            }
        }

        // return leftover tokens to owner
        if (balance0 > 0) {
            IERC20(token0).transfer(owner, balance0);
        }
        if (balance1 > 0) {
            IERC20(token1).transfer(owner, balance1);
        }

        emit RangeChanged(previousTokenId, tokenId);

        return IERC721Receiver.onERC721Received.selector;
    }

    // helper method to get pool for token
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(address(factory), PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    // helper method to get tickspacing for fee tier
    function _getTickSpacing(uint24 fee) internal pure returns (uint256) {
        if (fee == 10000) {
            return 200;
        } else if (fee == 3000) {
            return 60;
        } else if (fee == 500) {
            return 10;
        } else if (fee == 100) {
            return 1;
        } else {
            revert NotSupportedFeeTier();
        }
    }
}