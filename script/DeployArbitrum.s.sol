// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/InterestRateModel.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";

import "../src/transformers/V3Utils.sol";
import "../src/transformers/AutoRange.sol";
import "../src/transformers/AutoCompound.sol";
import "../src/transformers/LeverageTransformer.sol";

import "../src/automators/AutoExit.sol";

import "../src/utils/FlashloanLiquidator.sol";
import "../src/utils/ChainlinkFeedCombinator.sol";

contract DeployArbitrum is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy
    address UNIVERSAL_ROUTER = 0x5E325eDA8064b456f4781070C0738d849c824258;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // initially supported coins
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDC_E = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;

    AggregatorV3Interface constant WSTETH_ETH_FEED = AggregatorV3Interface(0xb523AE262D20A936BC152e6023996e46FDC2A95D);
    AggregatorV3Interface constant ETH_USD_FEED = AggregatorV3Interface(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);

    function run() external {
        vm.startBroadcast();
        
        // 5% base rate - after 80% - 109% (like in compound v2 deployed)
        InterestRateModel interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

        ChainlinkFeedCombinator wstethUsdFeed = new ChainlinkFeedCombinator(WSTETH_ETH_FEED, ETH_USD_FEED);

        V3Oracle oracle = new V3Oracle(NPM, address(WETH), address(0));
        oracle.setMaxPoolPriceDifference(200);
        oracle.setSequencerUptimeFeed(0xFdB631F5EE196F0ed6FAa767959853A9F217697D);

        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3),
            86400,
            IUniswapV3Pool(0xC6962004f452bE9203591991D15f6b388e09E8D0),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            USDC_E,
            AggregatorV3Interface(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3),
            86400,
            IUniswapV3Pool(0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            USDT,
            AggregatorV3Interface(0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7),
            86400,
            IUniswapV3Pool(0x641C00A822e8b671738d32a431a4Fb6074E5c79d),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            DAI,
            AggregatorV3Interface(0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB),
            86400,
            IUniswapV3Pool(0xA961F0473dA4864C5eD28e00FcC53a3AAb056c1b),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            WETH,
            AggregatorV3Interface(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612),
            86400,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.TWAP,
            0
        );
        oracle.setTokenConfig(
            WBTC,
            AggregatorV3Interface(0x6ce185860a4963106506C203335A2910413708e9),
            86400,
            IUniswapV3Pool(0x2f5e87C9312fa29aed5c179E456625D79015299c),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            ARB,
            AggregatorV3Interface(0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6),
            86400,
            IUniswapV3Pool(0xC6F780497A95e246EB9449f5e4770916DCd6396A),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            WSTETH,
            wstethUsdFeed,
            86400,
            IUniswapV3Pool(0x35218a1cbaC5Bbc3E57fd9Bd38219D37571b3537),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );

        V3Vault vault = new V3Vault("Revert Lend Arbitrum USDC", "rlArbUSDC", address(USDC), NPM, interestRateModel, oracle, IPermit2(PERMIT2));
        vault.setTokenConfig(USDC, uint32(Q32 * 850 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(USDC_E, uint32(Q32 * 850 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(USDT, uint32(Q32 * 850 / 1000), uint32(Q32 * 20 / 100)); // max 20% collateral value
        vault.setTokenConfig(DAI, uint32(Q32 * 850 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(WETH, uint32(Q32 *  775 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(WBTC, uint32(Q32 * 775 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(ARB, uint32(Q32 * 600 / 1000), uint32(Q32 * 20 / 100)); // max 20% collateral value
        vault.setTokenConfig(WSTETH, uint32(Q32 * 725 / 1000), type(uint32).max); // max 100% collateral value

        vault.setLimits(100000, 1000000000000, 399000000000000, 100000000000, 75000000000);
        vault.setReserveFactor(uint32(Q32 * 10 / 100));
        vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100));

        new FlashloanLiquidator(NPM, EX0x, UNIVERSAL_ROUTER);

        // deploy transformers and automators
        V3Utils v3Utils = V3Utils(payable(0xcfd55ac7647454Ea0F7C4c9eC231e0A282B30980));
        v3Utils.setVault(address(vault));
        vault.setTransformer(address(v3Utils), true);

        LeverageTransformer leverageTransformer = new LeverageTransformer(NPM, EX0x, UNIVERSAL_ROUTER);
        leverageTransformer.setVault(address(vault));
        vault.setTransformer(address(leverageTransformer), true);
        
        AutoRange autoRange = AutoRange(payable(0x5ff2195BA28d2544AeD91e30e5f74B87d4F158dE));
        autoRange.setVault(address(vault));
        vault.setTransformer(address(autoRange), true);
 
        AutoCompound autoCompound = AutoCompound(payable(0x9D97c76102E72883CD25Fa60E0f4143516d5b6db));
        autoCompound.setVault(address(vault));
        vault.setTransformer(address(autoCompound), true);

        //AutoExit autoExit = AutoExit();

        vm.stopBroadcast();
    }
}
