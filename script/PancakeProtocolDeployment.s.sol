// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../lib/AggregatorV3Interface.sol";
import "../src/InterestRateModel.sol";
import "../src/PancakeStakingManager.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";
import "../src/automators/AutoExit.sol";
import "../src/interfaces/pancake/IPancakeMasterChefV3.sol";
import "../src/transformers/AutoRangeAndCompound.sol";
import "../src/transformers/LeverageTransformer.sol";
import "../src/transformers/V3Utils.sol";
import "../src/utils/FlashloanLiquidator.sol";

abstract contract PancakeProtocolDeployment is Script {
    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;

    struct ChainConfig {
        uint256 chainId;
        string label;
        address npm;
        address masterChef;
        address cake;
        address wrappedNative;
        address defaultVaultAsset;
        string defaultVaultName;
        string defaultVaultSymbol;
    }

    struct DeploymentParams {
        uint256 privateKey;
        address deployer;
        address vaultAsset;
        address referenceToken;
        address chainlinkReferenceToken;
        address universalRouter;
        address zeroxAllowanceHolder;
        address operator;
        address withdrawer;
        address stakingWithdrawer;
        address owner;
        address oracleEmergencyAdmin;
        address vaultEmergencyAdmin;
        uint32 twapSeconds;
        uint16 maxTWAPTickDifference;
        bool allowEmptyConfig;
        bool setVaultGaugeManager;
    }

    struct Deployments {
        InterestRateModel interestRateModel;
        V3Oracle oracle;
        V3Vault vault;
        FlashloanLiquidator flashloanLiquidator;
        V3Utils v3Utils;
        LeverageTransformer leverageTransformer;
        AutoRangeAndCompound autoRange;
        AutoExit autoExit;
        PancakeStakingManager stakingManager;
    }

    struct OracleConfigArrays {
        address[] tokens;
        address[] feeds;
        uint256[] maxFeedAges;
        address[] pools;
        uint256[] twapSeconds;
        uint256[] modes;
        uint256[] maxDifferences;
    }

    function _deploy(ChainConfig memory cfg) internal {
        require(block.chainid == cfg.chainId, "PancakeDeploy: wrong chain");

        DeploymentParams memory params = _loadDeploymentParams(cfg);
        INonfungiblePositionManager npm = INonfungiblePositionManager(cfg.npm);
        IPancakeMasterChefV3 masterChef = IPancakeMasterChefV3(cfg.masterChef);
        IERC20 cake = IERC20(cfg.cake);

        _validateExternalConfig(cfg, params, npm, masterChef, cake);

        vm.startBroadcast(params.deployer);

        Deployments memory deployed;
        deployed.interestRateModel = _deployInterestRateModel();
        deployed.oracle = new V3Oracle(npm, params.referenceToken, params.chainlinkReferenceToken);
        _configureOracle(deployed.oracle, params.referenceToken, params.allowEmptyConfig);

        deployed.vault = new V3Vault(
            _envStringOrDefault("VAULT_NAME", cfg.defaultVaultName),
            _envStringOrDefault("VAULT_SYMBOL", cfg.defaultVaultSymbol),
            params.vaultAsset,
            npm,
            deployed.interestRateModel,
            deployed.oracle
        );
        _configureVault(deployed.vault, params.allowEmptyConfig);

        deployed.flashloanLiquidator = new FlashloanLiquidator(npm, params.universalRouter, params.zeroxAllowanceHolder);

        deployed.v3Utils = new V3Utils(npm, params.universalRouter, params.zeroxAllowanceHolder);
        deployed.v3Utils.setVault(address(deployed.vault));
        deployed.vault.setTransformer(address(deployed.v3Utils), true);

        deployed.leverageTransformer = new LeverageTransformer(npm, params.universalRouter, params.zeroxAllowanceHolder);
        deployed.leverageTransformer.setVault(address(deployed.vault));
        deployed.vault.setTransformer(address(deployed.leverageTransformer), true);

        deployed.autoRange = new AutoRangeAndCompound(
            npm,
            params.operator,
            params.withdrawer,
            params.twapSeconds,
            params.maxTWAPTickDifference,
            params.universalRouter,
            params.zeroxAllowanceHolder
        );
        deployed.autoRange.setVault(address(deployed.vault));
        deployed.vault.setTransformer(address(deployed.autoRange), true);

        deployed.autoExit = new AutoExit(
            npm,
            params.operator,
            params.withdrawer,
            params.twapSeconds,
            params.maxTWAPTickDifference,
            params.universalRouter,
            params.zeroxAllowanceHolder
        );

        deployed.stakingManager = new PancakeStakingManager(
            npm, masterChef, cake, deployed.vault, params.universalRouter, params.zeroxAllowanceHolder
        );
        _configureStakingManager(deployed.stakingManager, npm, masterChef, cfg.cake, params.allowEmptyConfig);
        deployed.stakingManager.setWithdrawer(params.stakingWithdrawer);

        if (params.setVaultGaugeManager) {
            deployed.vault.setGaugeManager(address(deployed.stakingManager));
        }
        if (params.oracleEmergencyAdmin != address(0)) {
            deployed.oracle.setEmergencyAdmin(params.oracleEmergencyAdmin);
        }
        if (params.vaultEmergencyAdmin != address(0)) {
            deployed.vault.setEmergencyAdmin(params.vaultEmergencyAdmin);
        }
        _transferOwnershipIfConfigured(deployed, params.owner);

        vm.stopBroadcast();

        _logDeployments(cfg, params, deployed);
    }

    function _loadDeploymentParams(ChainConfig memory cfg) internal returns (DeploymentParams memory params) {
        params.privateKey = vm.envUint("PRIVATE_KEY");
        params.deployer = vm.addr(params.privateKey);
        params.vaultAsset = _envAddressOrDefault("VAULT_ASSET", cfg.defaultVaultAsset);
        params.referenceToken = _envAddressOrDefault("REFERENCE_TOKEN", cfg.wrappedNative);
        params.chainlinkReferenceToken = _envAddressOrDefault("CHAINLINK_REFERENCE_TOKEN", address(0));
        params.universalRouter = _envAddressOrDefault("UNIVERSAL_ROUTER", address(0));
        params.zeroxAllowanceHolder = _envAddressOrDefault("ZEROX_ALLOWANCE_HOLDER", address(0));
        params.operator = _envAddressOrDefault("OPERATOR", params.deployer);
        params.withdrawer = _envAddressOrDefault("WITHDRAWER", params.deployer);
        params.stakingWithdrawer = _envAddressOrDefault("STAKING_WITHDRAWER", params.withdrawer);
        params.owner = _envAddressOrDefault("OWNER", address(0));
        params.oracleEmergencyAdmin = _envAddressOrDefault("ORACLE_EMERGENCY_ADMIN", address(0));
        params.vaultEmergencyAdmin = _envAddressOrDefault("VAULT_EMERGENCY_ADMIN", address(0));
        params.twapSeconds = _toUint32(_envUintOrDefault("AUTOMATOR_TWAP_SECONDS", 60));
        params.maxTWAPTickDifference = _toUint16(_envUintOrDefault("AUTOMATOR_MAX_TWAP_TICK_DIFFERENCE", 100));
        params.allowEmptyConfig = _envBoolOrDefault("ALLOW_EMPTY_CONFIG", false);
        params.setVaultGaugeManager = _envBoolOrDefault("SET_VAULT_GAUGE_MANAGER", true);
    }

    function _validateExternalConfig(
        ChainConfig memory cfg,
        DeploymentParams memory params,
        INonfungiblePositionManager npm,
        IPancakeMasterChefV3 masterChef,
        IERC20 cake
    ) internal view {
        _requireCode(cfg.npm, "PancakeDeploy: NPM missing code");
        _requireCode(cfg.masterChef, "PancakeDeploy: MasterChef missing code");
        _requireCode(cfg.cake, "PancakeDeploy: CAKE missing code");
        _requireCode(params.vaultAsset, "PancakeDeploy: asset missing code");
        _requireCode(params.referenceToken, "PancakeDeploy: reference token missing code");
        _requireNonZero(params.operator, "PancakeDeploy: operator zero");
        _requireNonZero(params.withdrawer, "PancakeDeploy: withdrawer zero");
        _requireNonZero(params.stakingWithdrawer, "PancakeDeploy: staking withdrawer zero");
        if (params.universalRouter != address(0)) {
            _requireCode(params.universalRouter, "PancakeDeploy: universal router missing code");
        }
        if (params.zeroxAllowanceHolder != address(0)) {
            _requireCode(params.zeroxAllowanceHolder, "PancakeDeploy: 0x allowance holder missing code");
        }
        require(masterChef.CAKE() == address(cake), "PancakeDeploy: CAKE mismatch");
        require(masterChef.nonfungiblePositionManager() == address(npm), "PancakeDeploy: NPM mismatch");
    }

    function _deployInterestRateModel() internal returns (InterestRateModel) {
        return new InterestRateModel(
            _envUintOrDefault("IRM_BASE_RATE_X64", 0),
            _envUintOrDefault("IRM_MULTIPLIER_X64", Q64 * 5 / 100),
            _envUintOrDefault("IRM_JUMP_MULTIPLIER_X64", Q64 * 109 / 100),
            _envUintOrDefault("IRM_KINK_X64", Q64 * 80 / 100)
        );
    }

    function _configureOracle(V3Oracle oracle, address referenceToken, bool allowEmptyConfig) internal {
        oracle.setMaxPoolPriceDifference(_toUint16(_envUintOrDefault("MAX_POOL_PRICE_DIFFERENCE", 200)));

        address sequencerUptimeFeed = _envAddressOrDefault("SEQUENCER_UPTIME_FEED", address(0));
        if (sequencerUptimeFeed != address(0)) {
            _requireCode(sequencerUptimeFeed, "PancakeDeploy: sequencer feed missing code");
            oracle.setSequencerUptimeFeed(sequencerUptimeFeed);
        }

        OracleConfigArrays memory config = OracleConfigArrays({
            tokens: _envAddressArrayOrEmpty("ORACLE_TOKENS"),
            feeds: _envAddressArrayOrEmpty("ORACLE_FEEDS"),
            maxFeedAges: _envUintArrayOrEmpty("ORACLE_MAX_FEED_AGES"),
            pools: _envAddressArrayOrEmpty("ORACLE_TWAP_POOLS"),
            twapSeconds: _envUintArrayOrEmpty("ORACLE_TWAP_SECONDS"),
            modes: _envUintArrayOrEmpty("ORACLE_MODES"),
            maxDifferences: _envUintArrayOrEmpty("ORACLE_MAX_DIFFERENCES")
        });

        if (config.tokens.length == 0) {
            require(allowEmptyConfig, "PancakeDeploy: oracle config empty");
            return;
        }

        _requireSameLength(config.tokens.length, config.feeds.length, "PancakeDeploy: oracle feed length");
        _requireSameLength(config.tokens.length, config.maxFeedAges.length, "PancakeDeploy: oracle feed age length");
        _requireSameLength(config.tokens.length, config.pools.length, "PancakeDeploy: oracle pool length");
        _requireSameLength(config.tokens.length, config.twapSeconds.length, "PancakeDeploy: oracle TWAP length");
        _requireSameLength(config.tokens.length, config.modes.length, "PancakeDeploy: oracle mode length");
        _requireSameLength(config.tokens.length, config.maxDifferences.length, "PancakeDeploy: oracle max diff length");

        for (uint256 i; i < config.tokens.length; ++i) {
            _configureOracleToken(oracle, referenceToken, config, i);
        }
    }

    function _configureOracleToken(V3Oracle oracle, address referenceToken, OracleConfigArrays memory config, uint256 i)
        internal
    {
        V3Oracle.Mode mode = _oracleMode(config.modes[i]);
        _requireCode(config.tokens[i], "PancakeDeploy: oracle token missing code");
        _requireCode(config.feeds[i], "PancakeDeploy: oracle feed missing code");
        if (_usesTWAP(mode) && config.tokens[i] != referenceToken) {
            _requireCode(config.pools[i], "PancakeDeploy: oracle TWAP pool missing code");
        }
        oracle.setTokenConfig(
            config.tokens[i],
            AggregatorV3Interface(config.feeds[i]),
            _toUint32(config.maxFeedAges[i]),
            IUniswapV3Pool(config.pools[i]),
            _toUint32(config.twapSeconds[i]),
            mode,
            _toUint16(config.maxDifferences[i])
        );
    }

    function _configureVault(V3Vault vault, bool allowEmptyConfig) internal {
        address[] memory tokens = _envAddressArrayOrEmpty("COLLATERAL_TOKENS");
        uint256[] memory collateralFactors = _loadFactorArray("COLLATERAL_FACTORS_X32", "COLLATERAL_FACTORS_BPS", false);
        uint256[] memory collateralValueLimitFactors =
            _loadFactorArray("COLLATERAL_VALUE_LIMIT_FACTORS_X32", "COLLATERAL_VALUE_LIMIT_FACTORS_BPS", true);

        if (tokens.length == 0) {
            require(allowEmptyConfig, "PancakeDeploy: collateral config empty");
        } else {
            _requireSameLength(tokens.length, collateralFactors.length, "PancakeDeploy: collateral factor length");
            _requireSameLength(
                tokens.length, collateralValueLimitFactors.length, "PancakeDeploy: collateral value limit factor length"
            );
            for (uint256 i; i < tokens.length; ++i) {
                _requireCode(tokens[i], "PancakeDeploy: collateral token missing code");
                vault.setTokenConfig(
                    tokens[i], _toUint32(collateralFactors[i]), _toUint32(collateralValueLimitFactors[i])
                );
            }
        }

        uint256 globalLendLimit = _envUintOrDefault("GLOBAL_LEND_LIMIT", 0);
        uint256 globalDebtLimit = _envUintOrDefault("GLOBAL_DEBT_LIMIT", 0);
        if (!allowEmptyConfig) {
            require(globalLendLimit != 0, "PancakeDeploy: global lend limit empty");
            require(globalDebtLimit != 0, "PancakeDeploy: global debt limit empty");
        }
        vault.setLimits(
            _envUintOrDefault("MIN_LOAN_SIZE", 0),
            globalLendLimit,
            globalDebtLimit,
            _envUintOrDefault("DAILY_LEND_INCREASE_LIMIT_MIN", 0),
            _envUintOrDefault("DAILY_DEBT_INCREASE_LIMIT_MIN", 0)
        );
        vault.setReserveFactor(_bpsToX32(_envUintOrDefault("RESERVE_FACTOR_BPS", 1000), true));
        vault.setReserveProtectionFactor(_bpsToX32(_envUintOrDefault("RESERVE_PROTECTION_FACTOR_BPS", 500), true));
    }

    function _configureStakingManager(
        PancakeStakingManager stakingManager,
        INonfungiblePositionManager npm,
        IPancakeMasterChefV3 masterChef,
        address cake,
        bool allowEmptyConfig
    ) internal {
        address[] memory rewardBaseTokens = _envAddressArrayOrEmpty("PANCAKE_REWARD_BASE_TOKENS");
        address[] memory rewardBasePools = _envAddressArrayOrEmpty("PANCAKE_REWARD_BASE_POOLS");
        address[] memory stakingPools = _envAddressArrayOrEmpty("PANCAKE_STAKING_POOLS");

        _requireSameLength(rewardBaseTokens.length, rewardBasePools.length, "PancakeDeploy: reward route length");
        if (!allowEmptyConfig) {
            require(rewardBaseTokens.length != 0, "PancakeDeploy: reward routes empty");
            require(stakingPools.length != 0, "PancakeDeploy: staking pools empty");
        }

        for (uint256 i; i < rewardBasePools.length; ++i) {
            _validateRewardPool(npm, cake, rewardBaseTokens[i], rewardBasePools[i]);
            stakingManager.setRewardBasePool(rewardBaseTokens[i], rewardBasePools[i]);
        }
        for (uint256 i; i < stakingPools.length; ++i) {
            _validateStakingPool(npm, masterChef, stakingPools[i]);
            stakingManager.setGauge(stakingPools[i], address(masterChef));
        }
    }

    function _transferOwnershipIfConfigured(Deployments memory deployed, address owner) internal {
        if (owner == address(0)) {
            return;
        }
        deployed.interestRateModel.transferOwnership(owner);
        deployed.oracle.transferOwnership(owner);
        deployed.vault.transferOwnership(owner);
        deployed.v3Utils.transferOwnership(owner);
        deployed.leverageTransformer.transferOwnership(owner);
        deployed.autoRange.transferOwnership(owner);
        deployed.autoExit.transferOwnership(owner);
        deployed.stakingManager.transferOwnership(owner);
    }

    function _validateRewardPool(INonfungiblePositionManager npm, address cake, address baseToken, address pool)
        internal
        view
    {
        _requireNonZero(baseToken, "PancakeDeploy: reward base token zero");
        _requireCode(baseToken, "PancakeDeploy: reward base token missing code");
        _requireCode(pool, "PancakeDeploy: reward pool missing code");
        IUniswapV3Pool rewardPool = IUniswapV3Pool(pool);
        address token0 = rewardPool.token0();
        address token1 = rewardPool.token1();
        require(token0 == cake && token1 == baseToken || token0 == baseToken && token1 == cake, "invalid reward pool");
        require(
            IUniswapV3Factory(npm.factory()).getPool(token0, token1, rewardPool.fee()) == pool,
            "PancakeDeploy: unknown reward pool"
        );
    }

    function _validateStakingPool(INonfungiblePositionManager npm, IPancakeMasterChefV3 masterChef, address pool)
        internal
        view
    {
        _requireCode(pool, "PancakeDeploy: staking pool missing code");
        uint256 pid = masterChef.v3PoolAddressPid(pool);
        require(pid != 0, "PancakeDeploy: staking pool not in MasterChef");
        (, IUniswapV3Pool v3Pool, address token0, address token1, uint24 fee,,) = masterChef.poolInfo(pid);
        require(address(v3Pool) == pool, "PancakeDeploy: MasterChef pool mismatch");
        require(
            IUniswapV3Factory(npm.factory()).getPool(token0, token1, fee) == pool, "PancakeDeploy: unknown staking pool"
        );
    }

    function _loadFactorArray(string memory x32Key, string memory bpsKey, bool fullBpsMeansNoLimit)
        internal
        returns (uint256[] memory values)
    {
        values = _envUintArrayOrEmpty(x32Key);
        if (values.length != 0) {
            return values;
        }

        uint256[] memory bpsValues = _envUintArrayOrEmpty(bpsKey);
        values = new uint256[](bpsValues.length);
        for (uint256 i; i < bpsValues.length; ++i) {
            values[i] = _bpsToX32(bpsValues[i], fullBpsMeansNoLimit);
        }
    }

    function _oracleMode(uint256 value) internal pure returns (V3Oracle.Mode) {
        require(value > uint256(V3Oracle.Mode.NOT_SET) && value <= uint256(V3Oracle.Mode.TWAP), "invalid oracle mode");
        return V3Oracle.Mode(value);
    }

    function _usesTWAP(V3Oracle.Mode mode) internal pure returns (bool) {
        return mode == V3Oracle.Mode.CHAINLINK_TWAP_VERIFY || mode == V3Oracle.Mode.TWAP_CHAINLINK_VERIFY
            || mode == V3Oracle.Mode.TWAP;
    }

    function _bpsToX32(uint256 bps, bool fullBpsMeansMax) internal pure returns (uint32) {
        require(bps <= 10_000, "PancakeDeploy: bps too high");
        if (fullBpsMeansMax && bps == 10_000) {
            return type(uint32).max;
        }
        return _toUint32(Q32 * bps / 10_000);
    }

    function _toUint32(uint256 value) internal pure returns (uint32) {
        require(value <= type(uint32).max, "PancakeDeploy: uint32 overflow");
        return uint32(value);
    }

    function _toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "PancakeDeploy: uint16 overflow");
        return uint16(value);
    }

    function _requireSameLength(uint256 expected, uint256 actual, string memory message) internal pure {
        require(actual == expected, message);
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _requireNonZero(address target, string memory errorMessage) internal pure {
        require(target != address(0), errorMessage);
    }

    function _envAddressOrDefault(string memory key, address defaultValue) internal returns (address value) {
        try vm.envAddress(key) returns (address configuredValue) {
            value = configuredValue;
        } catch {
            value = defaultValue;
        }
    }

    function _envBoolOrDefault(string memory key, bool defaultValue) internal returns (bool value) {
        try vm.envBool(key) returns (bool configuredValue) {
            value = configuredValue;
        } catch {
            value = defaultValue;
        }
    }

    function _envUintOrDefault(string memory key, uint256 defaultValue) internal returns (uint256 value) {
        try vm.envUint(key) returns (uint256 configuredValue) {
            value = configuredValue;
        } catch {
            value = defaultValue;
        }
    }

    function _envStringOrDefault(string memory key, string memory defaultValue) internal returns (string memory value) {
        try vm.envString(key) returns (string memory configuredValue) {
            value = configuredValue;
        } catch {
            value = defaultValue;
        }
    }

    function _envAddressArrayOrEmpty(string memory key) internal returns (address[] memory value) {
        try vm.envAddress(key, ",") returns (address[] memory configuredValue) {
            value = configuredValue;
        } catch {
            value = new address[](0);
        }
    }

    function _envUintArrayOrEmpty(string memory key) internal returns (uint256[] memory value) {
        try vm.envUint(key, ",") returns (uint256[] memory configuredValue) {
            value = configuredValue;
        } catch {
            value = new uint256[](0);
        }
    }

    function _logDeployments(ChainConfig memory cfg, DeploymentParams memory params, Deployments memory deployed)
        internal
        view
    {
        console2.log("CHAIN_ID", cfg.chainId);
        console2.log("DEPLOYER", params.deployer);
        console2.log("VAULT_ASSET", params.vaultAsset);
        console2.log("REFERENCE_TOKEN", params.referenceToken);
        console2.log("INTEREST_RATE_MODEL", address(deployed.interestRateModel));
        console2.log("ORACLE", address(deployed.oracle));
        console2.log("VAULT", address(deployed.vault));
        console2.log("FLASHLOAN_LIQUIDATOR", address(deployed.flashloanLiquidator));
        console2.log("V3_UTILS", address(deployed.v3Utils));
        console2.log("LEVERAGE_TRANSFORMER", address(deployed.leverageTransformer));
        console2.log("AUTO_RANGE", address(deployed.autoRange));
        console2.log("AUTO_EXIT", address(deployed.autoExit));
        console2.log("PANCAKE_STAKING_MANAGER", address(deployed.stakingManager));
        console2.log("PANCAKE_NPM", cfg.npm);
        console2.log("PANCAKE_MASTER_CHEF_V3", cfg.masterChef);
        console2.log("CAKE", cfg.cake);
        console2.log("OPERATOR", params.operator);
        console2.log("WITHDRAWER", params.withdrawer);
        console2.log("STAKING_WITHDRAWER", params.stakingWithdrawer);
        console2.log("OWNER", params.owner == address(0) ? params.deployer : params.owner);
        console2.log("SET_VAULT_GAUGE_MANAGER", params.setVaultGaugeManager);
    }
}
