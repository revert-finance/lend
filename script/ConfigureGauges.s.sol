// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/GaugeManager.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";

contract ConfigureGauges is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    // Base Slipstream pools
    address internal constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address internal constant CBBTC_USDC_POOL = 0x4e962BB3889Bf030368F56810A9c96B83CB3E778;

    function run() external {
        require(block.chainid == BASE_CHAIN_ID, "ConfigureGauges: wrong chain");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address gaugeManagerAddress = vm.envAddress("GAUGE_MANAGER");
        address wethUsdcGauge = vm.envAddress("WETH_USDC_GAUGE");
        address cbbtcUsdcGauge = _envAddressOrZero("CBBTC_USDC_GAUGE");

        _requireCode(gaugeManagerAddress, "ConfigureGauges: gauge manager missing code");
        _requireCode(WETH_USDC_POOL, "ConfigureGauges: WETH/USDC pool missing code");
        _requireCode(CBBTC_USDC_POOL, "ConfigureGauges: CBBTC/USDC pool missing code");
        _requireCode(wethUsdcGauge, "ConfigureGauges: WETH/USDC gauge missing code");
        if (cbbtcUsdcGauge != address(0)) {
            _requireCode(cbbtcUsdcGauge, "ConfigureGauges: CBBTC/USDC gauge missing code");
        }

        _requirePoolGaugeMatch(WETH_USDC_POOL, wethUsdcGauge);
        if (cbbtcUsdcGauge != address(0)) {
            _requirePoolGaugeMatch(CBBTC_USDC_POOL, cbbtcUsdcGauge);
        }

        GaugeManager gaugeManager = GaugeManager(gaugeManagerAddress);
        require(gaugeManager.owner() == deployer, "ConfigureGauges: deployer is not gauge manager owner");

        vm.startBroadcast();
        gaugeManager.setGauge(WETH_USDC_POOL, wethUsdcGauge);
        if (cbbtcUsdcGauge != address(0)) {
            gaugeManager.setGauge(CBBTC_USDC_POOL, cbbtcUsdcGauge);
        }
        vm.stopBroadcast();

        console2.log("DEPLOYER", deployer);
        console2.log("GAUGE_MANAGER", gaugeManagerAddress);
        console2.log("WETH_USDC_POOL", WETH_USDC_POOL);
        console2.log("WETH_USDC_GAUGE", gaugeManager.poolToGauge(WETH_USDC_POOL));
        console2.log("CBBTC_USDC_POOL", CBBTC_USDC_POOL);
        console2.log("CBBTC_USDC_GAUGE", gaugeManager.poolToGauge(CBBTC_USDC_POOL));
    }

    function _requirePoolGaugeMatch(address pool, address gauge) internal view {
        address poolGauge = IAerodromeSlipstreamPool(pool).gauge();
        require(poolGauge == gauge, "ConfigureGauges: pool gauge mismatch");
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _envAddressOrZero(string memory key) internal returns (address value) {
        try vm.envAddress(key) returns (address configuredValue) {
            value = configuredValue;
        } catch {
            value = address(0);
        }
    }
}
