// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./CoinbaseEquityBaseConfig.s.sol";

import "../src/InterestRateModel.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";
import "../src/utils/FlashloanLiquidator.sol";
import "../src/utils/ChainlinkMultiplierFeed.sol";
import "../src/transformers/V3Utils.sol";

/// @notice Stage A, step 3: deploys IRM, V3Oracle (configured), V3Vault (configured, borrows disabled)
///         and FlashloanLiquidator for the Coinbase B20 equity-collateral vault (plan WP4, §4).
///
///         Inputs: ADAPTER_* env vars from DeployBaseCoinbaseEquityAdapters.
///         Ownership: IRM is plain Ownable (transfer is immediate); V3Oracle and V3Vault are
///         Ownable2Step - this script only proposes the Safe and prints the acceptOwnership() batch.
///         Until the Safe accepts, the deployer remains owner and Stage A is not complete.
///         FlashloanLiquidator has no owner. emergencyAdmin is never set (matches the house).
///         globalDebtLimit is 0 at deploy: borrows stay disabled until Stage B.
///         Broadcast with `--skip-simulation` (B20 stand-ins exist only in the local run).
///
///         DRY_RUN=true (never with --broadcast): deploys the seven adapters inline instead of reading
///         ADAPTER_* and downgrades the V3Utils-ownership preflight to a warning, so the whole of
///         Stage A can be simulated before WP0.2 and step 2 have happened on chain.
contract DeployBaseCoinbaseEquityVault is CoinbaseEquityBaseConfig {
    bytes4 internal constant ACCEPT_OWNERSHIP = bytes4(keccak256("acceptOwnership()"));

    function run() external {
        bool dryRun = _envBoolOrFalse("DRY_RUN");
        Equity[7] memory eq = _equities();
        _installLocalB20Stubs(eq); // local run only: setTokenConfig reads token.decimals(), adapters read multiplier()

        address[7] memory adapters;
        if (dryRun) {
            console2.log("DRY_RUN: deploying adapters inline; V3Utils ownership check downgraded to a warning");
            vm.startBroadcast();
            for (uint256 i = 0; i < 7; i++) {
                adapters[i] = address(
                    new ChainlinkMultiplierFeed(AggregatorV3Interface(eq[i].feed), IB20Multiplier(eq[i].token))
                );
            }
            vm.stopBroadcast();
        } else {
            adapters = _readAdapters(eq);
        }
        _validateDeploymentConfig(eq, adapters, dryRun);

        IAerodromeNonfungiblePositionManager npm = IAerodromeNonfungiblePositionManager(AERODROME_NPM);

        // Signer comes from the CLI (--account deployer). No PRIVATE_KEY required.
        vm.startBroadcast();

        // 1. interest rate model: live Aerodrome parameters
        InterestRateModel irm = new InterestRateModel(0, Q64 * 13 / 100, Q64 * 300 / 100, Q64 * 90 / 100);

        // 2. oracle: USDC reference on its raw feed (forced CHAINLINK), equities via adapters
        V3Oracle oracle = new V3Oracle(npm, USDC, address(0));
        oracle.setMaxPoolPriceDifference(MAX_POOL_PRICE_DIFFERENCE);
        oracle.setSequencerUptimeFeed(CHAINLINK_BASE_SEQUENCER_UPTIME_FEED);
        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(CHAINLINK_USDC_USD),
            USDC_MAX_FEED_AGE,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );
        for (uint256 i = 0; i < 7; i++) {
            oracle.setTokenConfig(
                eq[i].token,
                AggregatorV3Interface(adapters[i]),
                EQUITY_MAX_FEED_AGE,
                IUniswapV3Pool(eq[i].pool),
                TWAP_SECONDS,
                V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
                EQUITY_MAX_DIFFERENCE
            );
        }
        // no setEmergencyAdmin: matches every live oracle

        // 3. vault: pilot factors and caps, borrows disabled
        V3Vault vault = new V3Vault(VAULT_NAME, VAULT_SYMBOL, USDC, npm, irm, oracle);
        vault.setTokenConfig(USDC, CF_USDC_X32, type(uint32).max);
        for (uint256 i = 0; i < 7; i++) {
            vault.setTokenConfig(eq[i].token, eq[i].collateralFactorX32, eq[i].collateralValueLimitFactorX32);
        }
        vault.setReserveFactor(RESERVE_FACTOR_X32);
        vault.setReserveProtectionFactor(RESERVE_PROTECTION_FACTOR_X32);
        vault.setLimits(MIN_LOAN_SIZE, GLOBAL_LEND_LIMIT, 0, DAILY_LEND_INCREASE_MIN, DAILY_DEBT_INCREASE_MIN);
        vault.setTransformer(V3_UTILS, true);
        // no setEmergencyAdmin: matches every live vault

        // 4. liquidator: no ownership, nothing to configure
        FlashloanLiquidator liquidator = new FlashloanLiquidator(npm, AERODROME_SWAP_ROUTER, ZEROX_ALLOWANCE_HOLDER);

        // 5. ownership: IRM immediate; oracle + vault proposed, Safe must accept
        irm.transferOwnership(BASE_MULTISIG);
        oracle.transferOwnership(BASE_MULTISIG);
        vault.transferOwnership(BASE_MULTISIG);

        vm.stopBroadcast();

        _verifyPostDeploy(irm, oracle, vault, eq, adapters);

        console2.log("IRM", address(irm));
        console2.log("ORACLE", address(oracle));
        console2.log("VAULT", address(vault));
        console2.log("LIQUIDATOR", address(liquidator));
        console2.log("V3_UTILS", V3_UTILS);
        console2.log("BASE_MULTISIG", BASE_MULTISIG);
        console2.log("GLOBAL_DEBT_LIMIT", vault.globalDebtLimit());

        // Safe batch closing Stage A
        _logSafeTx("oracle.acceptOwnership()", address(oracle), abi.encodeWithSelector(ACCEPT_OWNERSHIP));
        _logSafeTx("vault.acceptOwnership()", address(vault), abi.encodeWithSelector(ACCEPT_OWNERSHIP));
        // Stage B, step 5 (after Verify --stage a is green)
        _logSafeTx(
            "v3Utils.setVault(vault)", V3_UTILS, abi.encodeWithSignature("setVault(address)", address(vault))
        );
    }

    function _validateDeploymentConfig(Equity[7] memory eq, address[7] memory adapters, bool dryRun) internal view {
        _requireBaseInfra();
        _requireFreshFeed(CHAINLINK_USDC_USD, USDC_MAX_FEED_AGE, "USDC");
        _requireCode(CHAINLINK_BASE_SEQUENCER_UPTIME_FEED, "DeployVault: sequencer feed missing code");

        // V3Utils must already be Safe-owned with nothing pending (WP0.2, both steps)
        V3Utils v3Utils = V3Utils(payable(V3_UTILS));
        bool v3UtilsOwned = v3Utils.owner() == BASE_MULTISIG && v3Utils.pendingOwner() == address(0);
        if (dryRun && !v3UtilsOwned) {
            console2.log("WARNING: V3Utils owner is", v3Utils.owner(), "pendingOwner", v3Utils.pendingOwner());
            console2.log("WARNING: WP0.2 (transfer + Safe accept) must be done before the real deployment");
        } else {
            require(v3UtilsOwned, "DeployVault: V3Utils not owned by multisig (or pending owner set)");
        }
        require(
            address(v3Utils.nonfungiblePositionManager()) == AERODROME_NPM, "DeployVault: V3Utils NPM mismatch"
        );

        for (uint256 i = 0; i < 7; i++) {
            _validateEquityPool(eq[i]);
            ChainlinkMultiplierFeed adapter = ChainlinkMultiplierFeed(adapters[i]);
            require(address(adapter.feed()) == eq[i].feed, string.concat("DeployVault: adapter feed ", eq[i].symbol));
            require(address(adapter.token()) == eq[i].token, string.concat("DeployVault: adapter token ", eq[i].symbol));
            require(adapter.decimals() == 8, string.concat("DeployVault: adapter decimals ", eq[i].symbol));
            _requireFreshFeed(adapters[i], EQUITY_MAX_FEED_AGE, eq[i].symbol);
        }
    }

    function _envBoolOrFalse(string memory key) internal returns (bool value) {
        try vm.envBool(key) returns (bool configured) {
            value = configured;
        } catch {
            value = false;
        }
    }

    function _verifyPostDeploy(
        InterestRateModel irm,
        V3Oracle oracle,
        V3Vault vault,
        Equity[7] memory eq,
        address[7] memory adapters
    ) internal view {
        require(irm.owner() == BASE_MULTISIG, "DeployVault: IRM owner");
        require(oracle.owner() != BASE_MULTISIG, "DeployVault: oracle owner unexpectedly accepted");
        require(oracle.pendingOwner() == BASE_MULTISIG, "DeployVault: oracle pendingOwner");
        require(vault.pendingOwner() == BASE_MULTISIG, "DeployVault: vault pendingOwner");
        require(oracle.emergencyAdmin() == address(0), "DeployVault: oracle emergencyAdmin set");
        require(vault.emergencyAdmin() == address(0), "DeployVault: vault emergencyAdmin set");
        require(vault.globalDebtLimit() == 0, "DeployVault: borrows not disabled");
        require(vault.transformerAllowList(V3_UTILS), "DeployVault: V3Utils not allowed");

        for (uint256 i = 0; i < 7; i++) {
            (AggregatorV3Interface feed,,,,,,, V3Oracle.Mode mode,) = oracle.feedConfigs(eq[i].token);
            require(address(feed) == adapters[i], string.concat("DeployVault: oracle feed ", eq[i].symbol));
            require(
                mode == V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, string.concat("DeployVault: oracle mode ", eq[i].symbol)
            );
            (uint32 cf, uint32 cap,) = vault.tokenConfigs(eq[i].token);
            require(cf == eq[i].collateralFactorX32, string.concat("DeployVault: CF ", eq[i].symbol));
            require(cap == eq[i].collateralValueLimitFactorX32, string.concat("DeployVault: cap ", eq[i].symbol));
        }
    }
}
