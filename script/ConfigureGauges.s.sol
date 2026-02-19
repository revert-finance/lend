// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/GaugeManager.sol";

contract ConfigureGauges is Script {
    // Replace these after deploying GaugeManager.
    address internal constant GAUGE_MANAGER = 0x66a2481b784Cf26103441cA6067F997f90d3E129;

    // Base Slipstream pools
    address internal constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address internal constant CBBTC_USDC_POOL = 0x4e962BB3889Bf030368F56810A9c96B83CB3E778;

    // Gauge addresses
    address internal constant WETH_USDC_GAUGE = 0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8;
    address internal constant CBBTC_USDC_GAUGE = 0x6399ed6725cC163D019aA64FF55b22149D7179A8;

    function run() external {
        require(GAUGE_MANAGER != address(0), "Update GAUGE_MANAGER");
        require(WETH_USDC_GAUGE != address(0), "Missing WETH/USDC gauge");

        vm.startBroadcast();

        GaugeManager gaugeManager = GaugeManager(GAUGE_MANAGER);

        gaugeManager.setGauge(WETH_USDC_POOL, WETH_USDC_GAUGE);

        if (CBBTC_USDC_GAUGE != address(0)) {
            gaugeManager.setGauge(CBBTC_USDC_POOL, CBBTC_USDC_GAUGE);
        }

        vm.stopBroadcast();

        console2.log("GAUGE_MANAGER", GAUGE_MANAGER);
        console2.log("WETH_USDC_POOL", WETH_USDC_POOL);
        console2.log("WETH_USDC_GAUGE", gaugeManager.poolToGauge(WETH_USDC_POOL));
        console2.log("CBBTC_USDC_POOL", CBBTC_USDC_POOL);
        console2.log("CBBTC_USDC_GAUGE", gaugeManager.poolToGauge(CBBTC_USDC_POOL));
    }
}
