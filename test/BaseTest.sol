// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/external/uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import "../src/external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "../src/external/openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "../src/external/1inch/interfaces/IAggregationRouterV4.sol";

abstract contract BaseTest {
    
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    IUniswapV3Factory constant FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IAggregationRouterV4 constant SWAP = IAggregationRouterV4(0x1111111254fb6c44bAC0beD2854e76F90643097d);
}