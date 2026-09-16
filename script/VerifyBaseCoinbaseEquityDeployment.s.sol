// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./CoinbaseEquityBaseConfig.s.sol";

import "../src/InterestRateModel.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";
import "../src/utils/FlashloanLiquidator.sol";
import "../src/utils/ChainlinkMultiplierFeed.sol";
import "../src/transformers/V3Utils.sol";

/// @notice Read-only postcondition check for the Coinbase equity vault (plan WP4 / §6).
///         Env: ORACLE, VAULT, IRM, LIQUIDATOR, ADAPTER_* and STAGE ("a" or "b").
///         Stage A: everything deployed, Safe has accepted, borrows disabled, no setVault yet.
///         Stage B: additionally V3Utils.vaults(vault) is true; globalDebtLimit is 0 (weekend dry-run)
///         or the live value (borrows open).
///         Does not simulate borrow/repay/liquidate: stateless calls cannot chain and forks cannot run
///         B20 code - that is the on-chain smoke test. Run against a live Base RPC only.
contract VerifyBaseCoinbaseEquityDeployment is CoinbaseEquityBaseConfig {
    uint256 internal constant IMPLIED_PRICE_TOLERANCE_X10000 = 300; // adapter vs oracle quote, 3%

    function run() external {
        Equity[7] memory eq = _equities();
        address[7] memory adapters = _readAdapters(eq);
        V3Oracle oracle = V3Oracle(vm.envAddress("ORACLE"));
        V3Vault vault = V3Vault(vm.envAddress("VAULT"));
        InterestRateModel irm = InterestRateModel(vm.envAddress("IRM"));
        FlashloanLiquidator liquidator = FlashloanLiquidator(vm.envAddress("LIQUIDATOR"));
        bool stageB = keccak256(bytes(vm.envString("STAGE"))) == keccak256("b");

        _requireBaseInfra();
        _requireCode(address(oracle), "Verify: oracle missing code");
        _requireCode(address(vault), "Verify: vault missing code");
        _requireCode(address(irm), "Verify: IRM missing code");
        _requireCode(address(liquidator), "Verify: liquidator missing code");

        _verifyOwnership(oracle, vault, irm);
        _verifyOracle(oracle, eq, adapters);
        _verifyVault(vault, oracle, irm, eq);
        _verifyLiquidator(liquidator);
        _verifyStage(vault, stageB);

        console2.log("VERIFY OK", stageB ? "stage b" : "stage a");
        console2.log("  globalDebtLimit", vault.globalDebtLimit());
        console2.log("  debtSharesTotal", vault.debtSharesTotal());
        console2.log("  totalAssets    ", vault.totalAssets());
    }

    function _verifyOwnership(V3Oracle oracle, V3Vault vault, InterestRateModel irm) internal view {
        require(oracle.owner() == BASE_MULTISIG, "Verify: oracle owner");
        require(oracle.pendingOwner() == address(0), "Verify: oracle pendingOwner");
        require(vault.owner() == BASE_MULTISIG, "Verify: vault owner");
        require(vault.pendingOwner() == address(0), "Verify: vault pendingOwner");
        require(irm.owner() == BASE_MULTISIG, "Verify: IRM owner");
        V3Utils v3Utils = V3Utils(payable(V3_UTILS));
        require(v3Utils.owner() == BASE_MULTISIG, "Verify: V3Utils owner");
        require(v3Utils.pendingOwner() == address(0), "Verify: V3Utils pendingOwner");
        require(oracle.emergencyAdmin() == address(0), "Verify: oracle emergencyAdmin");
        require(vault.emergencyAdmin() == address(0), "Verify: vault emergencyAdmin");
    }

    function _verifyOracle(V3Oracle oracle, Equity[7] memory eq, address[7] memory adapters) internal view {
        require(address(oracle.nonfungiblePositionManager()) == AERODROME_NPM, "Verify: oracle NPM");
        require(oracle.factory() == AERODROME_FACTORY, "Verify: oracle factory");
        require(oracle.referenceToken() == USDC, "Verify: oracle referenceToken");
        require(oracle.chainlinkReferenceToken() == address(0), "Verify: chainlinkReferenceToken must be unset");
        require(oracle.maxPoolPriceDifference() == MAX_POOL_PRICE_DIFFERENCE, "Verify: maxPoolPriceDifference");
        require(oracle.sequencerUptimeFeed() == CHAINLINK_BASE_SEQUENCER_UPTIME_FEED, "Verify: sequencer feed");

        (AggregatorV3Interface usdcFeed, uint32 usdcAge,,,,,, V3Oracle.Mode usdcMode,) = oracle.feedConfigs(USDC);
        require(address(usdcFeed) == CHAINLINK_USDC_USD, "Verify: USDC feed");
        require(usdcAge == USDC_MAX_FEED_AGE, "Verify: USDC maxFeedAge");
        require(usdcMode == V3Oracle.Mode.CHAINLINK, "Verify: USDC mode");
        _requireFreshFeed(CHAINLINK_USDC_USD, USDC_MAX_FEED_AGE, "USDC");

        for (uint256 i = 0; i < 7; i++) {
            _validateEquityPool(eq[i]);
            (
                AggregatorV3Interface feed,
                uint32 maxFeedAge,
                uint8 feedDecimals,
                uint8 tokenDecimals,
                uint32 twapSeconds,
                IUniswapV3Pool pool,
                bool isToken0,
                V3Oracle.Mode mode,
                uint16 maxDifference
            ) = oracle.feedConfigs(eq[i].token);
            string memory s = eq[i].symbol;
            require(address(feed) == adapters[i], string.concat("Verify: feed ", s));
            require(maxFeedAge == EQUITY_MAX_FEED_AGE, string.concat("Verify: maxFeedAge ", s));
            require(feedDecimals == 8 && tokenDecimals == 8, string.concat("Verify: decimals ", s));
            require(twapSeconds == TWAP_SECONDS, string.concat("Verify: twapSeconds ", s));
            require(address(pool) == eq[i].pool, string.concat("Verify: pool ", s));
            require(!isToken0, string.concat("Verify: equity should be token1 ", s));
            require(mode == V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, string.concat("Verify: mode ", s));
            require(maxDifference == EQUITY_MAX_DIFFERENCE, string.concat("Verify: maxDifference ", s));

            ChainlinkMultiplierFeed adapter = ChainlinkMultiplierFeed(adapters[i]);
            require(address(adapter.feed()) == eq[i].feed, string.concat("Verify: adapter feed ", s));
            require(address(adapter.token()) == eq[i].token, string.concat("Verify: adapter token ", s));
            int256 tokenAnswer = _requireFreshFeed(adapters[i], EQUITY_MAX_FEED_AGE, s);

            // end-to-end quote through the oracle (all three checks run): 1 token -> USDC
            uint256 quoted = oracle.getTokenValue(eq[i].token, 1e8, USDC);
            uint256 expected = uint256(tokenAnswer) / 100; // 8-dec USD per token -> 6-dec USDC
            uint256 diff = quoted > expected ? quoted - expected : expected - quoted;
            require(diff * 10_000 / expected <= IMPLIED_PRICE_TOLERANCE_X10000, string.concat("Verify: quote ", s));
            console2.log(s, "quote USDC per token", quoted, "adapter");
            console2.log("        ", expected);
        }
    }

    function _verifyVault(V3Vault vault, V3Oracle oracle, InterestRateModel irm, Equity[7] memory eq) internal view {
        require(vault.asset() == USDC, "Verify: vault asset");
        require(address(vault.oracle()) == address(oracle), "Verify: vault oracle");
        require(address(vault.interestRateModel()) == address(irm), "Verify: vault IRM");
        require(address(vault.nonfungiblePositionManager()) == AERODROME_NPM, "Verify: vault NPM");
        require(vault.gaugeManager() == address(0), "Verify: gauge manager must be unset at pilot");
        require(vault.reserveFactorX32() == RESERVE_FACTOR_X32, "Verify: reserve factor");
        require(vault.reserveProtectionFactorX32() == RESERVE_PROTECTION_FACTOR_X32, "Verify: reserve protection");
        require(vault.minLoanSize() == MIN_LOAN_SIZE, "Verify: minLoanSize");
        require(vault.globalLendLimit() == GLOBAL_LEND_LIMIT, "Verify: globalLendLimit");
        require(vault.transformerAllowList(V3_UTILS), "Verify: V3Utils not in transformer allowlist");

        (uint32 usdcCf, uint32 usdcCap,) = vault.tokenConfigs(USDC);
        require(usdcCf == CF_USDC_X32 && usdcCap == type(uint32).max, "Verify: USDC vault config");
        for (uint256 i = 0; i < 7; i++) {
            (uint32 cf, uint32 cap,) = vault.tokenConfigs(eq[i].token);
            require(cf == eq[i].collateralFactorX32, string.concat("Verify: CF ", eq[i].symbol));
            require(cap == eq[i].collateralValueLimitFactorX32, string.concat("Verify: cap ", eq[i].symbol));
        }

        // IRM: live Aerodrome curve
        (uint256 borrowRateX64,) = irm.getRatesPerSecondX64(0, 0);
        require(borrowRateX64 == 0, "Verify: IRM base rate must be 0");
    }

    function _verifyLiquidator(FlashloanLiquidator liquidator) internal view {
        require(address(liquidator.nonfungiblePositionManager()) == AERODROME_NPM, "Verify: liquidator NPM");
        require(liquidator.factory() == AERODROME_FACTORY, "Verify: liquidator factory");
        require(liquidator.universalRouter() == AERODROME_SWAP_ROUTER, "Verify: liquidator router");
        require(liquidator.zeroxAllowanceHolder() == ZEROX_ALLOWANCE_HOLDER, "Verify: liquidator 0x");
    }

    function _verifyStage(V3Vault vault, bool stageB) internal view {
        V3Utils v3Utils = V3Utils(payable(V3_UTILS));
        if (!stageB) {
            require(vault.globalDebtLimit() == 0, "Verify: stage a requires globalDebtLimit == 0");
            require(vault.debtSharesTotal() == 0, "Verify: stage a requires no debt");
            require(!v3Utils.vaults(address(vault)), "Verify: stage a: setVault must not have run yet");
        } else {
            require(v3Utils.vaults(address(vault)), "Verify: stage b requires V3Utils.setVault(vault)");
            uint256 limit = vault.globalDebtLimit();
            require(limit == 0 || limit == GLOBAL_DEBT_LIMIT_LIVE, "Verify: stage b debt limit not 0 or live");
            require(vault.dailyLendIncreaseLimitMin() == DAILY_LEND_INCREASE_MIN, "Verify: daily lend min");
            require(vault.dailyDebtIncreaseLimitMin() == DAILY_DEBT_INCREASE_MIN, "Verify: daily debt min");
        }
    }
}
