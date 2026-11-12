// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/oracles/StockTwapFeed.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";

interface IStockFeedJsonVm {
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
}

/// @notice Deploys three immutable adapters only. Does not configure the oracle or enable borrowing.
contract DeployStockTwapFeeds is Script {
    IStockFeedJsonVm constant jsonVm = IStockFeedJsonVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (StockTwapFeed[3] memory adapters) {
        require(block.chainid == 8453, "Base only");
        string memory config = vm.readFile("config/aero-stock-collateral.json");
        address deployer = jsonVm.parseJsonAddress(config, ".deployer");
        address usdc = jsonVm.parseJsonAddress(config, ".usdc");
        AggregatorV3Interface usdcFeed = AggregatorV3Interface(jsonVm.parseJsonAddress(config, ".usdcFeed"));
        IAerodromeSlipstreamFactory factory = IAerodromeSlipstreamFactory(jsonVm.parseJsonAddress(config, ".factory"));
        uint256 maxAge = jsonVm.parseJsonUint(config, ".maxFeedAge");
        uint256 maxUsdcAge = jsonVm.parseJsonUint(config, ".maxUsdcFeedAge");
        uint256 window = jsonVm.parseJsonUint(config, ".twapSeconds");
        uint256 tolerance = jsonVm.parseJsonUint(config, ".maxDifferenceBps");
        require(maxAge == 86400 && maxUsdcAge == 86400 && window == 60 && tolerance == 200, "Review policy changes");
        address[3] memory stocks;
        AggregatorV3Interface[3] memory feeds;
        IUniswapV3Pool[3] memory pools;
        // Preflight every adapter's exact constructor and price check before recording any broadcast.
        // Native B20 decimals are verified separately by prepare-aero-stock-collateral.py on Base.
        for (uint256 i; i < 3; ++i) {
            string memory prefix = string.concat(".assets[", vm.toString(i), "]");
            stocks[i] = jsonVm.parseJsonAddress(config, string.concat(prefix, ".token"));
            feeds[i] = AggregatorV3Interface(jsonVm.parseJsonAddress(config, string.concat(prefix, ".feed")));
            pools[i] = IUniswapV3Pool(jsonVm.parseJsonAddress(config, string.concat(prefix, ".pool")));
            require(
                factory.getPool(stocks[i], usdc, pools[i].tickSpacing()) == address(pools[i]), "Incorrect Aero pool"
            );
            StockTwapFeed probe = new StockTwapFeed(
                feeds[i],
                usdcFeed,
                pools[i],
                stocks[i],
                usdc,
                uint32(maxAge),
                uint32(maxUsdcAge),
                uint32(window),
                uint16(tolerance)
            );
            probe.latestRoundData();
        }
        vm.startBroadcast(deployer);
        for (uint256 i; i < 3; ++i) {
            adapters[i] = new StockTwapFeed(
                feeds[i],
                usdcFeed,
                pools[i],
                stocks[i],
                usdc,
                uint32(maxAge),
                uint32(maxUsdcAge),
                uint32(window),
                uint16(tolerance)
            );
        }
        vm.stopBroadcast();
        for (uint256 i; i < 3; ++i) {
            console2.log("STOCK", stocks[i]);
            console2.log("ADAPTER", address(adapters[i]));
        }
    }
}
