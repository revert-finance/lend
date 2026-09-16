// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./CoinbaseEquityBaseConfig.s.sol";
import "../src/utils/ChainlinkMultiplierFeed.sol";

/// @notice Stage A, step 2: deploys the seven ChainlinkMultiplierFeed adapters (plan WP4).
///         Adapters are immutable and ownerless - there is no ownership step. Export the logged
///         ADAPTER_* addresses before running DeployBaseCoinbaseEquityVault.
///
///         B20 tokens are native client code that revm cannot execute; the script etches a local
///         stand-in (LocalB20Stub, fed with the live multiplier via eth_call) for its own run.
///         Broadcast with `--skip-simulation`; dry-run against a live Base RPC, never a local fork.
contract DeployBaseCoinbaseEquityAdapters is CoinbaseEquityBaseConfig {
    function run() external returns (address[7] memory adapters) {
        Equity[7] memory eq = _equities();
        _installLocalB20Stubs(eq); // local run only; see CoinbaseEquityBaseConfig
        _validateDeploymentConfig(eq);

        // Signer comes from the CLI (--account deployer). No PRIVATE_KEY required.
        vm.startBroadcast();
        for (uint256 i = 0; i < 7; i++) {
            adapters[i] = address(
                new ChainlinkMultiplierFeed(AggregatorV3Interface(eq[i].feed), IB20Multiplier(eq[i].token))
            );
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < 7; i++) {
            _verifyAdapter(eq[i], ChainlinkMultiplierFeed(adapters[i]));
            console2.log(eq[i].adapterEnv, adapters[i]);
        }
    }

    function _validateDeploymentConfig(Equity[7] memory eq) internal view {
        _requireBaseInfra();
        for (uint256 i = 0; i < 7; i++) {
            _requireCode(eq[i].token, string.concat("DeployAdapters: token missing code ", eq[i].symbol));
            _requireCode(eq[i].feed, string.concat("DeployAdapters: feed missing code ", eq[i].symbol));
            require(
                AggregatorV3Interface(eq[i].feed).decimals() == 8,
                string.concat("DeployAdapters: feed decimals != 8 ", eq[i].symbol)
            );
            require(
                IERC20Metadata(eq[i].token).decimals() == 8,
                string.concat("DeployAdapters: token decimals != 8 ", eq[i].symbol)
            );
            require(
                IB20Multiplier(eq[i].token).multiplier() > 0,
                string.concat("DeployAdapters: multiplier() == 0 ", eq[i].symbol)
            );
            _requireFreshFeed(eq[i].feed, EQUITY_MAX_FEED_AGE, eq[i].symbol);
        }
    }

    function _verifyAdapter(Equity memory e, ChainlinkMultiplierFeed adapter) internal view {
        require(address(adapter.feed()) == e.feed, string.concat("DeployAdapters: adapter feed mismatch ", e.symbol));
        require(address(adapter.token()) == e.token, string.concat("DeployAdapters: adapter token mismatch ", e.symbol));
        require(adapter.decimals() == 8, string.concat("DeployAdapters: adapter decimals ", e.symbol));

        (, int256 shareAnswer,,,) = AggregatorV3Interface(e.feed).latestRoundData();
        uint256 multiplier = IB20Multiplier(e.token).multiplier();
        (, int256 tokenAnswer,,,) = adapter.latestRoundData();
        require(
            tokenAnswer == int256(uint256(shareAnswer) * multiplier / 1e18),
            string.concat("DeployAdapters: adapter answer mismatch ", e.symbol)
        );
        console2.log(e.symbol, "share answer", uint256(shareAnswer), "multiplier");
        console2.log("        ", multiplier, "token answer", uint256(tokenAnswer));
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
