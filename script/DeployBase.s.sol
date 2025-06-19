// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/InterestRateModel.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";
import "../src/utils/FlashloanLiquidator.sol";
import "../src/transformers/V3Utils.sol";
import "../src/transformers/AutoRange.sol";
import "../src/transformers/AutoCompound.sol";
import "../src/transformers/LeverageTransformer.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "permit2/interfaces/IPermit2.sol";

contract DeployBase is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    // Base addresses
    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
    address constant EX0x = 0x0000000000001fF3684f28c67538d4D072C22734;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Tokens
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    // Chainlink Feeds (Base mainnet, from official docs)
    AggregatorV3Interface constant USDC_USD_FEED = AggregatorV3Interface(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B);
    AggregatorV3Interface constant ETH_USD_FEED = AggregatorV3Interface(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
    AggregatorV3Interface constant CBBTC_USD_FEED = AggregatorV3Interface(0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D);

    // Uniswap V3 pools (Base) - All against WETH for better liquidity
    address constant USDC_WETH_005 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant CBBTC_WETH_030 = 0x8c7080564B5A792A33Ef2FD473fbA6364d5495e5;

    // Already deployed transformer addresses (from ConfigureBase)
    address constant V3_UTILS = 0x98eC492942090364AC0736Ef1A741AE6C92ec790;
    address constant AUTO_RANGE = 0xA8549424B20a514Eb9e7a829ec013065Bef9Dc1D;
    address constant AUTO_COMPOUND = 0x0bF485Bd7EbB82e282F72E7d14822C680E3f7bEC;

    // Team multisig address for ownership transfers
    address constant TEAM_MULTISIG = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;

    function run() external {
        vm.startBroadcast();

        console.log("Deploying to Base...");
        console.log("Deployer:", msg.sender);
        console.log("=== FULL DEPLOYMENT MODE ===");
        console.log("Using WETH as reference token for better liquidity");
        console.log("Supported tokens: USDC, WETH, CBBTC");

        // Deploy Interest Rate Model (updated kink to 90%)
        console.log("Deploying InterestRateModel...");
        InterestRateModel interestRateModel = new InterestRateModel(
            0,                          // Base rate: 0%
            2398076729557582000,        // Multiplier: 75990465991 * 31557600 (12% APR)
            55340232221128654848,       // Jump multiplier: 300% APR (1753626138271 * 31557600)
            16602069666338596454        // Kink: 90% in Q64
        );
        console.log("InterestRateModel deployed at:", address(interestRateModel));

        // Deploy Oracle with WETH as reference token
        console.log("Deploying V3Oracle with WETH as reference token...");
        V3Oracle oracle = new V3Oracle(NPM, address(WETH), address(0));
        console.log("V3Oracle deployed at:", address(oracle));

        // Configure Oracle
        oracle.setMaxPoolPriceDifference(200); // 2% max divergence
        
        // Set sequencer uptime feed for Base L2
        console.log("Configuring sequencer uptime feed for Base L2...");
        oracle.setSequencerUptimeFeed(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433);

        // Configure WETH (reference token)
        console.log("Configuring WETH as reference token...");
        oracle.setTokenConfig(
            WETH,
            ETH_USD_FEED,
            3600,                      // 1 hour heartbeat
            IUniswapV3Pool(address(0)), // No pool needed for reference token
            0,
            V3Oracle.Mode.TWAP,
            0
        );

        // Configure USDC
        console.log("Configuring USDC...");
        oracle.setTokenConfig(
            USDC,
            USDC_USD_FEED,
            86400,                     // 24 hours heartbeat
            IUniswapV3Pool(USDC_WETH_005),
            60,                        // 1 minute TWAP
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200                        // 2% max divergence
        );

        // Configure CBBTC
        console.log("Configuring CBBTC...");
        oracle.setTokenConfig(
            CBBTC,
            CBBTC_USD_FEED,
            86400,
            IUniswapV3Pool(CBBTC_WETH_030),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );

        // Deploy V3Vault
        console.log("Deploying V3Vault...");
        V3Vault vault = new V3Vault(
            "Revert Lend Base USDC",
            "rlBaseUSDC",
            address(USDC),
            NPM,
            interestRateModel,
            oracle,
            IPermit2(PERMIT2)
        );
        console.log("V3Vault deployed at:", address(vault));

        // Configure collateral factors for supported tokens
        console.log("Configuring collateral factors...");
        vault.setTokenConfig(USDC, uint32(Q32 * 850 / 1000), type(uint32).max); // 85%
        vault.setTokenConfig(WETH, uint32(Q32 * 775 / 1000), type(uint32).max); // 77.5%
        vault.setTokenConfig(CBBTC, uint32(Q32 * 775 / 1000), type(uint32).max); // 77.5%

        // Set limits (conservative for Base)
        console.log("Setting vault limits...");
        vault.setLimits(
            1000000,         // Min loan size: $1 USDC
            20000000000000,   // Global lend limit: $20,000,000 USDC
            2000000000000,    // Global debt limit: $20,000,000 USDC
            2000000000000,    // Daily lend increase limit min: $2,000,000 USDC
            2000000000000     // Daily debt increase limit min: $2,000,000 USDC
        );

        // Set reserve factor (10% of interest goes to reserves)
        vault.setReserveFactor(uint32(Q32 * 10 / 100));
        // Set reserve protection (5% of lent amount must stay as reserves)
        vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100));

        // Deploy FlashloanLiquidator
        console.log("Deploying FlashloanLiquidator...");
        FlashloanLiquidator liquidator = new FlashloanLiquidator(NPM, UNIVERSAL_ROUTER, EX0x);
        console.log("FlashloanLiquidator deployed at:", address(liquidator));

        // Deploy LeverageTransformer
        console.log("Deploying LeverageTransformer...");
        LeverageTransformer transformer = new LeverageTransformer(
            NPM,
            UNIVERSAL_ROUTER,
            EX0x
        );
        console.log("LeverageTransformer deployed at:", address(transformer));

        // Configure two-way authorization for LeverageTransformer
        console.log("Configuring LeverageTransformer...");
        vault.setTransformer(address(transformer), true);
        transformer.setVault(address(vault));

        // Configure all transformers with the vault
        console.log("Configuring transformers with vault...");
        
        // Configure V3Utils
        vault.setTransformer(address(V3_UTILS), true);
        V3Utils(payable(V3_UTILS)).setVault(address(vault));
        
        // Configure AutoRange
        vault.setTransformer(address(AUTO_RANGE), true);
        // Note: AutoRange doesn't need setVault() call as it's stateless
        
        // Configure AutoCompound
        vault.setTransformer(address(AUTO_COMPOUND), true);
        // Note: AutoCompound doesn't need setVault() call as it's stateless

        // Transfer ownership of all deployed contracts
        console.log("Transferring ownership of deployed contracts...");
        
        // Transfer vault ownership
        vault.transferOwnership(TEAM_MULTISIG);
        console.log("Vault ownership transferred to:", TEAM_MULTISIG);
        
        // Transfer oracle ownership
        oracle.transferOwnership(TEAM_MULTISIG);
        console.log("Oracle ownership transferred to:", TEAM_MULTISIG);
        
        // Transfer interest rate model ownership
        interestRateModel.transferOwnership(TEAM_MULTISIG);
        console.log("InterestRateModel ownership transferred to:", TEAM_MULTISIG);
        
        // Transfer transformer ownership
        transformer.transferOwnership(TEAM_MULTISIG);
        console.log("LeverageTransformer ownership transferred to:", TEAM_MULTISIG);
        
        // Transfer V3Utils ownership
        V3Utils(payable(V3_UTILS)).transferOwnership(TEAM_MULTISIG);
        console.log("V3Utils ownership transferred to:", TEAM_MULTISIG);

        vm.stopBroadcast();

        // Print deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base");
        console.log("Reference Token: WETH (for better liquidity)");
        console.log("Vault Asset: USDC");
        console.log("InterestRateModel:", address(interestRateModel));
        console.log("V3Oracle:", address(oracle));
        console.log("V3Vault:", address(vault));
        console.log("FlashloanLiquidator:", address(liquidator));
        console.log("LeverageTransformer:", address(transformer));
        console.log("V3Utils:", address(V3_UTILS));
        console.log("AutoRange:", address(AUTO_RANGE));
        console.log("AutoCompound:", address(AUTO_COMPOUND));
        console.log("\nSupported Tokens:");
        console.log("- USDC: 85% collateral factor");
        console.log("- WETH: 77.5% collateral factor");
        console.log("- CBBTC: 77.5% collateral factor");
        console.log("\nPool Configuration:");
        console.log("- USDC/WETH 0.05%:", USDC_WETH_005);
        console.log("- CBBTC/WETH 0.30%:", CBBTC_WETH_030);
        console.log("\nDeployment completed successfully!");
    }
} 