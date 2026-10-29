// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/InterestRateModel.sol";
import "../src/poolside/PoolsideFactory.sol";
import "../src/utils/FlashloanLiquidator.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";
import "../src/GaugeManager.sol";
import "../src/automators/AutoExit.sol";
import "../src/transformers/LeverageTransformer.sol";
import "../src/transformers/AutoRangeAndCompound.sol";
import "../src/transformers/V3Utils.sol";
import "../src/interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";

/// @dev Deployed before startBroadcast, for simulation only. Foundry disallows address(this) in scripts;
/// the shared validator probes pendingRedeems(address(this)) without depending on the returned balance.
contract AeroDeploymentPreflight {
    function validate(address gauge, address rewardToken) external view returns (address) {
        return AeroRewardDelivery.validate(gauge, rewardToken);
    }
}

contract DeployAeroProtocol is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;

    // Base / Aerodrome
    address internal constant AERODROME_NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address internal constant AERODROME_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address internal constant AERODROME_GAUGE_FACTORY = 0xf437f62053ACB121665b8fDBfeA8F214FB8E589d;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;

    // Routing infra
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // Production roles
    address internal constant BASE_MULTISIG = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address internal constant MULTICHAIN_WITHDRAWER = 0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82;
    address internal constant MULTICHAIN_OPERATOR = 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF;

    // Chainlink feeds on Base
    address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant CHAINLINK_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant CHAINLINK_BASE_SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Base Slipstream pools
    address internal constant WETH_USDC_POOL = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c;
    address internal constant CBBTC_WETH_POOL = 0xbB5507DaaE822ba89C4dA61BbfDf4b49a1666BAc;
    address internal constant AERO_USDC_POOL = 0xD0Acf293547457Fb4fE9eE32CA93e89497626816;
    address internal constant AERO_WETH_POOL = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3;
    address internal constant AERO_CBBTC_POOL = 0xe6A7317DF4A9a7540663B99A07d1e019CAa8Afa4;

    // Fresh Base deployment. No existing vault state is migrated. Borrowing starts disabled.
    // A complete simulation is required before broadcasting; every broadcast call is a separate transaction.
    struct Deployment {
        V3Oracle oracle;
        InterestRateModel irm;
        V3Vault vault;
        V3Utils v3Utils;
        GaugeManager gaugeManager;
        LeverageTransformer leverageTransformer;
        AutoRangeAndCompound autoRange;
        AutoExit autoExit;
        FlashloanLiquidator liquidator;
        PoolsideFactory poolsideFactory;
    }

    function collateralPools() public pure returns (address[] memory pools) {
        pools = new address[](6);
        pools[0] = WETH_USDC_POOL;
        pools[1] = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24;
        pools[2] = CBBTC_WETH_POOL;
        pools[3] = 0xeC3c3755b9DED4a2960ef50C9b48C1694CE274C2;
        pools[4] = 0x42609aA1E58C5dD7E5a012DC74118fFf975F0Eac;
        pools[5] = 0x784E539F15Ca2D19449a6311c5dAb6cF37d8f1ba;
    }

    function run() external returns (Deployment memory deployed) {
        validateDeploymentConfig();

        address deployer = vm.envAddress("AERO_DEPLOYER");
        require(deployer == 0x83681C14770b44361e21Faf91D8325423365eA5C, "unexpected deployer");

        vm.startBroadcast(deployer);

        IAerodromeNonfungiblePositionManager npm = IAerodromeNonfungiblePositionManager(AERODROME_NPM);

        V3Oracle oracle = new V3Oracle(npm, WETH, address(0));

        InterestRateModel irm = new InterestRateModel(
            0, // base rate
            Q64 * 13 / 100, // multiplier (13%)
            Q64 * 300 / 100, // jump multiplier (300%)
            Q64 * 90 / 100 // kink (90%)
        );

        V3Vault vault = new V3Vault("Revert Lend Aero USDC", "rlAeroUSDC", USDC, npm, irm, oracle);

        V3Utils v3Utils = new V3Utils(npm, UNIVERSAL_ROUTER, ZEROX_ALLOWANCE_HOLDER);

        GaugeManager gaugeManager =
            new GaugeManager(npm, IERC20(AERO), IVault(address(vault)), UNIVERSAL_ROUTER, ZEROX_ALLOWANCE_HOLDER);
        address[] memory pools = collateralPools();
        for (uint256 i; i < pools.length; ++i) {
            gaugeManager.setGauge(pools[i], IAerodromeSlipstreamPool(pools[i]).gauge());
        }
        gaugeManager.setRewardBasePool(USDC, AERO_USDC_POOL);
        gaugeManager.setRewardBasePool(WETH, AERO_WETH_POOL);
        gaugeManager.setRewardBasePool(CBBTC, AERO_CBBTC_POOL);

        LeverageTransformer leverageTransformer = new LeverageTransformer(npm, UNIVERSAL_ROUTER, ZEROX_ALLOWANCE_HOLDER);

        AutoRangeAndCompound autoRange = new AutoRangeAndCompound(
            npm,
            MULTICHAIN_OPERATOR,
            MULTICHAIN_WITHDRAWER,
            60, // TWAP seconds
            100, // max TWAP tick diff
            UNIVERSAL_ROUTER,
            ZEROX_ALLOWANCE_HOLDER
        );

        AutoExit autoExit = new AutoExit(
            npm,
            MULTICHAIN_OPERATOR,
            MULTICHAIN_WITHDRAWER,
            60, // TWAP seconds
            100, // max TWAP tick diff
            UNIVERSAL_ROUTER,
            ZEROX_ALLOWANCE_HOLDER
        );

        FlashloanLiquidator liquidator = new FlashloanLiquidator(npm, UNIVERSAL_ROUTER, ZEROX_ALLOWANCE_HOLDER);
        gaugeManager.setCompoundModeSource(address(autoRange));

        // Oracle config
        oracle.setMaxPoolPriceDifference(200);
        oracle.setSequencerUptimeFeed(CHAINLINK_BASE_SEQUENCER_UPTIME_FEED);

        oracle.setTokenConfig(
            WETH,
            AggregatorV3Interface(CHAINLINK_ETH_USD),
            3600,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );

        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(CHAINLINK_USDC_USD),
            86400,
            IUniswapV3Pool(WETH_USDC_POOL),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );

        oracle.setTokenConfig(
            CBBTC,
            AggregatorV3Interface(CHAINLINK_CBBTC_USD),
            86400,
            IUniswapV3Pool(CBBTC_WETH_POOL),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );

        // Vault config
        vault.setGaugeManager(address(gaugeManager));

        gaugeManager.setWithdrawer(MULTICHAIN_WITHDRAWER);
        v3Utils.setVault(address(vault));
        leverageTransformer.setVault(address(vault));
        autoRange.setVault(address(vault));

        vault.setTransformer(address(v3Utils), true);
        vault.setTransformer(address(leverageTransformer), true);
        vault.setTransformer(address(autoRange), true);
        vault.setStakingPolicy(address(autoRange));

        vault.setLimits(
            1e6, // minLoanSize = 1 USDC
            1_000_000e6, // global lend limit
            0, // borrowing disabled; Safe activation is a separate transaction
            100_000e6, // daily lend increase min
            100_000e6 // daily debt increase min
        );

        // A same-timestamp simulation skips interest accrual; real broadcast transactions cross blocks.
        vault.setReserveFactor{gas: 250_000}(uint32(10 * Q32 / 100));
        vault.setReserveProtectionFactor(uint32(5 * Q32 / 100));

        vault.setTokenConfig(USDC, uint32(85 * Q32 / 100), type(uint32).max);
        vault.setTokenConfig(WETH, uint32(775 * Q32 / 1000), type(uint32).max);
        vault.setTokenConfig(CBBTC, uint32(775 * Q32 / 1000), type(uint32).max);

        PoolsideFactory poolsideFactory = new PoolsideFactory(v3Utils, vault, autoRange, autoExit);
        autoExit.setOperator(address(poolsideFactory), true);

        oracle.transferOwnership(BASE_MULTISIG);
        irm.transferOwnership(BASE_MULTISIG);
        vault.transferOwnership(BASE_MULTISIG);
        gaugeManager.transferOwnership(BASE_MULTISIG);
        v3Utils.transferOwnership(BASE_MULTISIG);
        leverageTransformer.transferOwnership(BASE_MULTISIG);
        autoRange.transferOwnership(BASE_MULTISIG);
        autoExit.transferOwnership(BASE_MULTISIG);

        vm.stopBroadcast();
        deployed = Deployment(
            oracle,
            irm,
            vault,
            v3Utils,
            gaugeManager,
            leverageTransformer,
            autoRange,
            autoExit,
            liquidator,
            poolsideFactory
        );
        require(vault.gaugeManager() == address(gaugeManager), "vault binding");
        require(address(gaugeManager.vault()) == address(vault), "manager binding");
        require(vault.globalDebtLimit() == 0, "borrowing enabled prematurely");
        require(gaugeManager.compoundModeSource() == address(autoRange), "fee source");
        require(vault.stakingPolicy() == address(autoRange), "staking policy");

        console2.log("DEPLOYER", deployer);
        console2.log("BASE_MULTISIG", BASE_MULTISIG);
        console2.log("MULTICHAIN_WITHDRAWER", MULTICHAIN_WITHDRAWER);
        console2.log("MULTICHAIN_OPERATOR", MULTICHAIN_OPERATOR);
        console2.log("AERODROME_FACTORY", AERODROME_FACTORY);
        console2.log("AERODROME_GAUGE_FACTORY", AERODROME_GAUGE_FACTORY);
        console2.log("ORACLE", address(oracle));
        console2.log("IRM", address(irm));
        console2.log("VAULT", address(vault));
        console2.log("GAUGE_MANAGER", address(gaugeManager));
        console2.log("V3_UTILS", address(v3Utils));
        console2.log("V3_UTILS_DEPLOYED", true);
        console2.log("V3_UTILS_VAULT_CONFIGURED", true);
        console2.log("LEVERAGE_TRANSFORMER", address(leverageTransformer));
        console2.log("AUTO_RANGE", address(autoRange));
        console2.log("AUTO_EXIT", address(autoExit));
        console2.log("FLASHLOAN_LIQUIDATOR", address(liquidator));
        console2.log("POOLSIDE_FACTORY", address(poolsideFactory));
        require(autoExit.operators(address(poolsideFactory)), "holder exit operator");
    }

    function validateDeploymentConfig() public {
        AeroDeploymentPreflight preflight = new AeroDeploymentPreflight();
        require(block.chainid == BASE_CHAIN_ID, "DeployAeroProtocol: wrong chain");
        _requireCode(AERODROME_NPM, "DeployAeroProtocol: NPM missing code");
        _requireCode(AERODROME_FACTORY, "DeployAeroProtocol: factory missing code");
        _requireCode(AERODROME_GAUGE_FACTORY, "DeployAeroProtocol: gauge factory missing code");
        _requireCode(UNIVERSAL_ROUTER, "DeployAeroProtocol: aerodrome router missing code");
        _requireCode(ZEROX_ALLOWANCE_HOLDER, "DeployAeroProtocol: 0x allowance holder missing code");
        _requireCode(BASE_MULTISIG, "DeployAeroProtocol: base multisig missing code");
        _requireNonZero(MULTICHAIN_WITHDRAWER, "DeployAeroProtocol: withdrawer zero");
        _requireNonZero(MULTICHAIN_OPERATOR, "DeployAeroProtocol: operator zero");
        _requireCode(CHAINLINK_BASE_SEQUENCER_UPTIME_FEED, "DeployAeroProtocol: sequencer uptime feed missing code");

        IAerodromeNonfungiblePositionManager npm = IAerodromeNonfungiblePositionManager(AERODROME_NPM);
        require(npm.factory() == AERODROME_FACTORY, "DeployAeroProtocol: NPM factory mismatch");
        require(npm.WETH9() == WETH, "NPM WETH mismatch");
        address[] memory pools = collateralPools();
        for (uint256 i; i < pools.length; ++i) {
            IAerodromeSlipstreamPool pool = IAerodromeSlipstreamPool(pools[i]);
            _validatePool(pools[i], pool.token0(), pool.token1());
            address gauge = pool.gauge();
            require(IAeroGauge(gauge).nft() == AERODROME_NPM && IAeroGauge(gauge).pool() == pools[i], "gauge bindings");
            require(preflight.validate(gauge, AERO) == 0x8C37F30F3c8fd48bEddb14086fa5148291D422C3, "root handler");
        }
        _validateFeed(CHAINLINK_ETH_USD, 3600);
        _validateFeed(CHAINLINK_USDC_USD, 86400);
        _validateFeed(CHAINLINK_CBBTC_USD, 86400);
        (, int256 status, uint256 startedAt,,) =
            AggregatorV3Interface(CHAINLINK_BASE_SEQUENCER_UPTIME_FEED).latestRoundData();
        require(status == 0 && block.timestamp > startedAt + 3600, "sequencer unavailable");
        _validatePool(WETH_USDC_POOL, WETH, USDC);
        _validatePool(CBBTC_WETH_POOL, CBBTC, WETH);
        _validatePool(AERO_USDC_POOL, AERO, USDC);
        _validatePool(AERO_WETH_POOL, AERO, WETH);
        _validatePool(AERO_CBBTC_POOL, AERO, CBBTC);
    }

    function _validatePool(address pool, address tokenA, address tokenB) internal view {
        _requireCode(pool, "DeployAeroProtocol: pool missing code");
        IAerodromeSlipstreamPool slipstreamPool = IAerodromeSlipstreamPool(pool);

        address token0 = slipstreamPool.token0();
        address token1 = slipstreamPool.token1();
        require(
            (token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA),
            "DeployAeroProtocol: pool token mismatch"
        );

        require(IUniswapV3Pool(pool).liquidity() > 0, "pool has no active liquidity");
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 60;
        IUniswapV3Pool(pool).observe(secondsAgos);
        address resolved =
            IAerodromeSlipstreamFactory(AERODROME_FACTORY).getPool(token0, token1, slipstreamPool.tickSpacing());
        require(resolved == pool, "DeployAeroProtocol: pool not from factory");
    }

    function _validateFeed(address feed, uint256 maxAge) internal view {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(
            answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge,
            "invalid/stale feed"
        );
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _requireNonZero(address target, string memory errorMessage) internal pure {
        require(target != address(0), errorMessage);
    }
}
