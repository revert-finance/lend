// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/InterestRateModel.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";

import "../src/utils/FlashloanLiquidator.sol";

contract DeployPolygon is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q96 = 2 ** 96;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy
    address UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    address constant WMATIC_USDC_005 = 0xA374094527e1673A86dE625aa59517c5dE346d32;

    function run() external {
        vm.startBroadcast();

        // 5% base rate - after 80% - 109% (like in compound v2 deployed)
        InterestRateModel interestRateModel = new InterestRateModel(0, Q96 * 5 / 100, Q96 * 109 / 100, Q96 * 80 / 100); //InterestRateModel(0x7d6411cbA65Cb81F8Ff9723dA66e8aa0d58E8355);//

        // use tolerant oracles (so timewarp for until 30 days works in tests - also allow divergence from price for mocked price results)
        V3Oracle oracle = new V3Oracle(NPM, address(USDC), address(0)); //V3Oracle(0x3A22Fe0aB53478F071c66Fce166b033C35562CED)
        oracle.setMaxPoolPriceDifference(200);

        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7),
            3600,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.TWAP,
            0
        );
        oracle.setTokenConfig(
            WMATIC,
            AggregatorV3Interface(0xAB594600376Ec9fD91F8e885dADF0CE036862dE0),
            3600,
            IUniswapV3Pool(WMATIC_USDC_005),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            WETH,
            AggregatorV3Interface(0xF9680D99D6C9589e2a93a78A04A279e509205945),
            3600,
            IUniswapV3Pool(0x45dDa9cb7c25131DF268515131f647d726f50608),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            WBTC,
            AggregatorV3Interface(0xc907E116054Ad103354f2D350FD2514433D57F6f),
            3600,
            IUniswapV3Pool(0x847b64f9d3A95e977D157866447a5C0A5dFa0Ee5),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );

        V3Vault vault =
            new V3Vault("Revert Lend USDC", "rlUSDC", address(USDC), NPM, interestRateModel, oracle, IPermit2(PERMIT2));
        vault.setTokenConfig(USDC, uint32(Q32 * 8 / 10), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(WMATIC, uint32(Q32 * 8 / 10), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(WETH, uint32(Q32 * 8 / 10), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(WBTC, uint32(Q32 * 8 / 10), type(uint32).max); // max 100% collateral value

        // limits 100 USDC each
        vault.setLimits(0, 100000000, 100000000, 100000000, 100000000);

        new FlashloanLiquidator(NPM, EX0x, UNIVERSAL_ROUTER);

        vm.stopBroadcast();
    }
}
