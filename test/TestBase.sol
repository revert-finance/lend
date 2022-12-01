// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract TestBase {
    
    uint256 constant Q64 = 2**64;

    int24 constant MIN_TICK_100 = -887272;
    int24 constant MIN_TICK_500 = -887270;

    IERC20 constant WETH_ERC20 = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    address FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy

    address constant COMPOUND_COMPTROLLER = 0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B; 
    address constant COMPOUND_ORACLE = 0x65c816077C29b557BEE980ae3cC2dCE80204A0C5; // current compound oracle

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address constant TEST_ACCOUNT = 0x8cadb20A4811f363Dadb863A190708bEd26245F8;

    uint256 constant TEST_NFT_ID = 24181; // DAI/USCD 0.05% - one sided only DAI - current tick is near -276326 - no liquidity (-276320/-276310)
    uint256 constant TEST_NFT_ID_IN_RANGE = 23901; // DAI/USCD 0.05% - two sided

    uint256 constant TEST_NFT_WITH_FEES = 4660;
    address constant TEST_NFT_WITH_FEES_POOL = 0x6c6Bc977E13Df9b0de53b251522280BB72383700;
    address constant TEST_NFT_WITH_FEES_ACCOUNT = 0xa3eF006a7da5BcD1144d8BB86EfF1734f46A0c1E;


    // DAI WETH 0.3% out of range / with liquidity and fees
    uint256 constant TEST_NFT_2 = 7;
    address constant TEST_NFT_2_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    address constant TEST_NFT_2_POOL = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8;

    address constant TEST_FEE_ACCOUNT = 0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB;

    address constant TEST_NFT_ETH_USDC_POOL = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant TEST_NFT_ETH_USDC_ACCOUNT = 0x96653b13bD00842Eb8Bc77dCCFd48075178733ce;
    uint constant TEST_NFT_ETH_USDC = 827;
}