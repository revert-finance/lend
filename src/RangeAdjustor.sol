// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./V3Utils.sol";

/// @title RangeAdjustor
/// @notice Allows owner of RangeAdjustor contract (Revert controlled bot) to change range for configured positions
/// Positions need to be approved for the contract and configured with setConfig method
contract RangeAdjustor is Ownable {

    error Unauthorized();
    error WrongContract();
    error InvalidConfig();
    error NotSupportedFeeTier();

    event RangeChanged(uint256 indexed oldTokenId, uint256 indexed newTokenId);

    uint256 private constant Q64 = 2**64; 
    uint256 private constant Q96 = 2**96; 

    V3Utils public immutable v3Utils;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;

    struct PositionConfig {
        int24 lowerTickLimit; // if negative also in-range positions may be adjusted
        int24 upperTickLimit; // if negative also in-range positions may be adjusted

        int24 lowerTickDelta; // must be 0 or a negative multiple of tick spacing
        int24 upperTickDelta; // must greater than 0 and positive multiple of tick spacing

        int64 maxSlippageX64; // max allowed swap slippage including fees, price impact and slippage - from current pool price (to be sure revert bot can not do silly things)
    }

    mapping(uint => PositionConfig) public configs;

    constructor(V3Utils _v3Utils, address _swapRouter)  {
        v3Utils = _v3Utils;
        INonfungiblePositionManager npm = _v3Utils.nonfungiblePositionManager();
        nonfungiblePositionManager = npm;
        factory = IUniswapV3Factory(npm.factory());
    }

    /**
     * @notice Sets config for a given NFT - must be owner
     */
    function setConfig(uint tokenId, PositionConfig calldata config) external {

        if (config.lowerTickDelta < 0 || config.upperTickDelta < 0) {
            revert InvalidConfig();
        }

        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }
        configs[tokenId] = config;
    }

    struct AdjustParams {
        uint tokenId;
        bool swap0To1;
        uint256 amountIn;
        bytes swapData;
        uint deadline;
    }

    /**
     * @notice Adjust token (must be in correct state)
     * Swap needs to be done with max price difference from current pool price
     */
    function adjust(AdjustParams calldata params) onlyOwner external returns (uint256 newTokenId) 
    {
        PositionConfig storage config = configs[params.tokenId];
        (,,address token0,address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = nonfungiblePositionManager.positions(params.tokenId);
        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = pool.slot0();

        if (currentTick < tickLower - config.lowerTickLimit || currentTick >= tickUpper + config.upperTickLimit) {

            // calculate with current pool price 
            uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
            uint256 minAmountOut = FullMath.mul(Q64 - maxSlippageX64, params.swap0To1 ? FullMath.mulDiv(params.amountIn, priceX96, Q96) : FullMath.mulDiv(params.amountIn, Q96, priceX96), Q64);
            uint24 tickSpacing = _getTickSpacing(fee);

            address owner = nonfungiblePositionManager.ownerOf(tokenId);
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
                owner,
                address(this), // TODO needs to be able to redirect the new NFT - needs change in V3Utils
                true,
                "",
                abi.encode(owner, params.tokenId) // sent along with new NFT to onERC721Received callback
            ));
            nonfungiblePositionManager.safeTransferFrom(owner, address(v3Utils), tokenId, data);
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

        (address owner, uint256 previousTokenId) = abi.decode(data, (address, uint256));

        // copy token config for new token
        configs[tokenId] = configs[previousTokenId];

        nonfungiblePositionManager.safeTransferFrom(address(this), owner, tokenId, data);

        emit RangeChanged(previousTokenId, tokenId);
    }

    // helper method to get pool for token
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(address(factory), PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    // helper method to get tickspacing for fee tier
    function _getTickSpacing(uint24 fee) internal pure returns (uint) {
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