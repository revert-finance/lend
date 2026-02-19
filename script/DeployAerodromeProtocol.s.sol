// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/InterestRateModel.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";
import "../src/GaugeManager.sol";
import "../src/transformers/LeverageTransformer.sol";
import "../src/transformers/AutoCompound.sol";
import "../src/interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";

contract DeployAerodromeProtocol is Script {
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
    address internal constant UNIVERSAL_ROUTER = 0x198EF79F1F515F02dFE9e3115eD9fC07183f02fC;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Chainlink feeds on Base
    address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant CHAINLINK_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    // Base Slipstream pools
    address internal constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address internal constant CBBTC_USDC_POOL = 0x4e962BB3889Bf030368F56810A9c96B83CB3E778;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast();

        IAerodromeNonfungiblePositionManager npm = IAerodromeNonfungiblePositionManager(AERODROME_NPM);

        V3Oracle oracle = new V3Oracle(npm, USDC, address(0));

        InterestRateModel irm = new InterestRateModel(
            0, // base rate
            Q64 * 15 / 1000, // multiplier (1.5%)
            Q64, // jump multiplier (100%)
            Q64 * 80 / 100 // kink (80%)
        );

        V3Vault vault = new V3Vault(
            "Revert Lend USDC",
            "rlUSDC",
            USDC,
            npm,
            irm,
            oracle,
            IPermit2(PERMIT2)
        );

        GaugeManager gaugeManager = new GaugeManager(
            npm,
            IERC20(AERO),
            IVault(address(vault)),
            UNIVERSAL_ROUTER,
            ZEROX_ALLOWANCE_HOLDER
        );

        LeverageTransformer leverageTransformer =
            new LeverageTransformer(npm, UNIVERSAL_ROUTER, ZEROX_ALLOWANCE_HOLDER);

        AutoCompound autoCompound = new AutoCompound(
            npm,
            deployer, // operator
            deployer, // withdrawer
            60, // TWAP seconds
            200 // max TWAP tick diff
        );

        // Oracle config
        oracle.setMaxPoolPriceDifference(200);

        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(CHAINLINK_USDC_USD),
            86400,
            IUniswapV3Pool(address(0)),
            60,
            V3Oracle.Mode.CHAINLINK,
            type(uint16).max
        );

        oracle.setTokenConfig(
            WETH,
            AggregatorV3Interface(CHAINLINK_ETH_USD),
            3600,
            IUniswapV3Pool(WETH_USDC_POOL),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );

        oracle.setTokenConfig(
            CBBTC,
            AggregatorV3Interface(CHAINLINK_BTC_USD),
            3600,
            IUniswapV3Pool(CBBTC_USDC_POOL),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );

        // Vault config
        vault.setGaugeManager(address(gaugeManager));

        leverageTransformer.setVault(address(vault));
        autoCompound.setVault(address(vault));

        vault.setTransformer(address(leverageTransformer), true);
        vault.setTransformer(address(autoCompound), true);

        vault.setLimits(
            1e6, // minLoanSize = 1 USDC
            10_000_000e6, // global lend limit
            8_000_000e6, // global debt limit
            1_000_000e6, // daily lend increase min
            1_000_000e6 // daily debt increase min
        );

        vault.setReserveFactor(uint32(10 * Q32 / 100));

        vault.setTokenConfig(USDC, uint32(90 * Q32 / 100), type(uint32).max);
        vault.setTokenConfig(WETH, uint32(85 * Q32 / 100), type(uint32).max);
        vault.setTokenConfig(CBBTC, uint32(85 * Q32 / 100), type(uint32).max);

        vm.stopBroadcast();

        console2.log("DEPLOYER", deployer);
        console2.log("AERODROME_FACTORY", AERODROME_FACTORY);
        console2.log("AERODROME_GAUGE_FACTORY", AERODROME_GAUGE_FACTORY);
        console2.log("ORACLE", address(oracle));
        console2.log("IRM", address(irm));
        console2.log("VAULT", address(vault));
        console2.log("GAUGE_MANAGER", address(gaugeManager));
        console2.log("LEVERAGE_TRANSFORMER", address(leverageTransformer));
        console2.log("AUTO_COMPOUND", address(autoCompound));
    }
}
