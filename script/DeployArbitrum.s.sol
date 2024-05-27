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

contract DeployArbitrum is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy
    address UNIVERSAL_ROUTER = 0x5E325eDA8064b456f4781070C0738d849c824258;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    function run() external {
        vm.startBroadcast();

        // 5% base rate - after 80% - 109% (like in compound v2 deployed)
        InterestRateModel interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

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

        V3Vault vault =
            new V3Vault("RLT USDC", "rltUSDC", address(USDC), NPM, interestRateModel, oracle, IPermit2(PERMIT2));
        vault.setTokenConfig(USDC, uint32(Q32 * 850 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(DAI, uint32(Q32 * 850 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(WETH, uint32(Q32 *  775 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(WBTC, uint32(Q32 * 775 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(ARB, uint32(Q32 * 680 / 1000), type(uint32).max); // max 100% collateral value

        // limits 100 USDC each
        vault.setLimits(0, 100000000, 100000000, 100000000, 100000000);
        vault.setReserveFactor(uint32(Q32 * 7 / 100));
        vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100));

        new FlashloanLiquidator(NPM, EX0x, UNIVERSAL_ROUTER);

        // deploy transformers and automators
        V3Utils v3Utils = new V3Utils(NPM, EX0x, UNIVERSAL_ROUTER, PERMIT2);
        v3Utils.setVault(address(vault));
        vault.setTransformer(address(v3Utils), true);

        LeverageTransformer leverageTransformer = new LeverageTransformer(NPM, EX0x, UNIVERSAL_ROUTER);
        leverageTransformer.setVault(address(vault));
        vault.setTransformer(address(leverageTransformer), true);
        
        AutoRange autoRange = new AutoRange(NPM, 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF, 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF, 60, 100, EX0x, UNIVERSAL_ROUTER);
        autoRange.setVault(address(vault));
        vault.setTransformer(address(autoRange), true);
 
        AutoCompound autoCompound = new AutoCompound(NPM, 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF, 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF, 60, 100);
        autoCompound.setVault(address(vault));
        vault.setTransformer(address(autoCompound), true);

        AutoExit autoExit = new AutoExit(NPM, 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF, 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF, 60, 100, EX0x, UNIVERSAL_ROUTER);

        vm.stopBroadcast();
    }
}
