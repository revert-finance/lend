// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/external/uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import "../src/external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "../src/external/openzeppelin/token/ERC20/utils/SafeERC20.sol";

import "../src/external/IWETH.sol";

abstract contract TestBase {
    
    int24 constant MIN_TICK_100 = -887272;
    int24 constant MIN_TICK_500 = -887270;

    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IERC20 constant WETH_ERC20 = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    address constant POLYGON_BRIDGE = 0xA0c68C638235ee32657e8f720a23ceC1bFc77C77; // use this for ALL tokens - reverts if token not mapped

    address constant OPTIMISM_BRIDGE_STANDARD = 0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1; // for WETH us this / for others tokenlist 
    address constant OPTIMISM_USDC = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
    address constant OPTIMISM_BRIDGE_DAI = 0x10E6593CDda8c58a1d0f14C5164B376352a55f2F;
    address constant OPTIMISM_DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy
}