// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/InterestRateModel.sol";
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

contract DeployAerodromeProtocol is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;

    // Base / Aerodrome
    address internal constant AERODROME_NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant AERODROME_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant AERODROME_GAUGE_FACTORY = 0xD30677bd8dd15132F251Cb54CbDA552d2A05Fb08;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // Routing infra
    address internal constant AERODROME_SWAP_ROUTER = 0x6Cb442acF35158D5eDa88fe602221b67B400Be3E;
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
    address internal constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address internal constant CBBTC_WETH_POOL = 0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1;
    address internal constant AERO_USDC_POOL = 0xBE00fF35AF70E8415D0eB605a286D8A45466A4c1;
    address internal constant AERO_WETH_POOL = 0x82321f3BEB69f503380D6B233857d5C43562e2D0;
    address internal constant AERO_CBBTC_POOL = 0xdFe5F275020def30993f042174Fc2D335678b626;

    function run() external {
        _validateDeploymentConfig();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployer);

        IAerodromeNonfungiblePositionManager npm = IAerodromeNonfungiblePositionManager(AERODROME_NPM);

        V3Oracle oracle = new V3Oracle(npm, WETH, address(0));

        InterestRateModel irm = new InterestRateModel(
            0, // base rate
            Q64 * 13 / 100, // multiplier (13%)
            Q64 * 300 / 100, // jump multiplier (300%)
            Q64 * 90 / 100 // kink (90%)
        );

        V3Vault vault = new V3Vault("Revert Lend Aerodrome USDC", "rlAeroUSDC", USDC, npm, irm, oracle);

        V3Utils v3Utils = new V3Utils(npm, AERODROME_SWAP_ROUTER, ZEROX_ALLOWANCE_HOLDER);

        GaugeManager gaugeManager =
            new GaugeManager(npm, IERC20(AERO), IVault(address(vault)), AERODROME_SWAP_ROUTER, ZEROX_ALLOWANCE_HOLDER);
        gaugeManager.setRewardBasePool(USDC, AERO_USDC_POOL);
        gaugeManager.setRewardBasePool(WETH, AERO_WETH_POOL);
        gaugeManager.setRewardBasePool(CBBTC, AERO_CBBTC_POOL);

        LeverageTransformer leverageTransformer =
            new LeverageTransformer(npm, AERODROME_SWAP_ROUTER, ZEROX_ALLOWANCE_HOLDER);

        AutoRangeAndCompound autoRange = new AutoRangeAndCompound(
            npm,
            MULTICHAIN_OPERATOR,
            MULTICHAIN_WITHDRAWER,
            60, // TWAP seconds
            100, // max TWAP tick diff
            AERODROME_SWAP_ROUTER,
            ZEROX_ALLOWANCE_HOLDER
        );

        AutoExit autoExit = new AutoExit(
            npm,
            MULTICHAIN_OPERATOR,
            MULTICHAIN_WITHDRAWER,
            60, // TWAP seconds
            100, // max TWAP tick diff
            AERODROME_SWAP_ROUTER,
            ZEROX_ALLOWANCE_HOLDER
        );

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

        vault.setLimits(
            1e6, // minLoanSize = 1 USDC
            25_000_000e6, // global lend limit
            22_500_000e6, // global debt limit
            5_000_000e6, // daily lend increase min
            4_500_000e6 // daily debt increase min
        );

        vault.setReserveFactor(uint32(10 * Q32 / 100));
        vault.setReserveProtectionFactor(uint32(5 * Q32 / 100));

        vault.setTokenConfig(USDC, uint32(85 * Q32 / 100), type(uint32).max);
        vault.setTokenConfig(WETH, uint32(775 * Q32 / 1000), type(uint32).max);
        vault.setTokenConfig(CBBTC, uint32(775 * Q32 / 1000), type(uint32).max);

        oracle.transferOwnership(BASE_MULTISIG);
        irm.transferOwnership(BASE_MULTISIG);
        vault.transferOwnership(BASE_MULTISIG);
        gaugeManager.transferOwnership(BASE_MULTISIG);
        v3Utils.transferOwnership(BASE_MULTISIG);
        leverageTransformer.transferOwnership(BASE_MULTISIG);
        autoRange.transferOwnership(BASE_MULTISIG);
        autoExit.transferOwnership(BASE_MULTISIG);

        vm.stopBroadcast();

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
    }

    function _validateDeploymentConfig() internal view {
        require(block.chainid == BASE_CHAIN_ID, "DeployAerodromeProtocol: wrong chain");
        _requireCode(AERODROME_NPM, "DeployAerodromeProtocol: NPM missing code");
        _requireCode(AERODROME_FACTORY, "DeployAerodromeProtocol: factory missing code");
        _requireCode(AERODROME_GAUGE_FACTORY, "DeployAerodromeProtocol: gauge factory missing code");
        _requireCode(AERODROME_SWAP_ROUTER, "DeployAerodromeProtocol: aerodrome router missing code");
        _requireCode(ZEROX_ALLOWANCE_HOLDER, "DeployAerodromeProtocol: 0x allowance holder missing code");
        _requireCode(BASE_MULTISIG, "DeployAerodromeProtocol: base multisig missing code");
        _requireNonZero(MULTICHAIN_WITHDRAWER, "DeployAerodromeProtocol: withdrawer zero");
        _requireNonZero(MULTICHAIN_OPERATOR, "DeployAerodromeProtocol: operator zero");
        _requireCode(
            CHAINLINK_BASE_SEQUENCER_UPTIME_FEED, "DeployAerodromeProtocol: sequencer uptime feed missing code"
        );

        IAerodromeNonfungiblePositionManager npm = IAerodromeNonfungiblePositionManager(AERODROME_NPM);
        require(npm.factory() == AERODROME_FACTORY, "DeployAerodromeProtocol: NPM factory mismatch");
        _validatePool(WETH_USDC_POOL, WETH, USDC);
        _validatePool(CBBTC_WETH_POOL, CBBTC, WETH);
        _validatePool(AERO_USDC_POOL, AERO, USDC);
        _validatePool(AERO_WETH_POOL, AERO, WETH);
        _validatePool(AERO_CBBTC_POOL, AERO, CBBTC);
    }

    function _validatePool(address pool, address tokenA, address tokenB) internal view {
        _requireCode(pool, "DeployAerodromeProtocol: pool missing code");
        IAerodromeSlipstreamPool slipstreamPool = IAerodromeSlipstreamPool(pool);

        address token0 = slipstreamPool.token0();
        address token1 = slipstreamPool.token1();
        require(
            (token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA),
            "DeployAerodromeProtocol: pool token mismatch"
        );

        address resolved =
            IAerodromeSlipstreamFactory(AERODROME_FACTORY).getPool(token0, token1, slipstreamPool.tickSpacing());
        require(resolved == pool, "DeployAerodromeProtocol: pool not from factory");
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _requireNonZero(address target, string memory errorMessage) internal pure {
        require(target != address(0), errorMessage);
    }
}
