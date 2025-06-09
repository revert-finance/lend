// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/InterestRateModel.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";

import "../src/utils/FlashloanLiquidator.sol";
import "../src/utils/ChainlinkFeedCombinator.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "permit2/interfaces/IPermit2.sol";

contract DeployMainnet is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    // Mainnet addresses
    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant EX0x = 0x0000000000001fF3684f28c67538d4D072C22734; // 0x v2 AllowanceHolder
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Mainnet tokens
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Mainnet Chainlink feeds
    AggregatorV3Interface constant USDC_USD_FEED = AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
    AggregatorV3Interface constant ETH_USD_FEED = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    AggregatorV3Interface constant DAI_USD_FEED = AggregatorV3Interface(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9);
    AggregatorV3Interface constant USDT_USD_FEED = AggregatorV3Interface(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D);
    AggregatorV3Interface constant BTC_USD_FEED = AggregatorV3Interface(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);

    // Mainnet Uniswap V3 pools (all paired with WETH as reference token)
    address constant USDC_ETH_005 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // 0.05% fee
    address constant DAI_ETH_030 = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8;   // 0.30% fee  
    address constant USDT_ETH_030 = 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36;  // 0.30% fee
    address constant WBTC_ETH_030 = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD; // 0.30% fee

    function run() external {
        vm.startBroadcast();
        
        console.log("Deploying to Ethereum Mainnet...");
        console.log("Deployer:", msg.sender);

        // Deploy Interest Rate Model
        // 0% base rate, ~13% multiplier, ~200% jump multiplier after ~85% utilization
        // Values calculated to match Arbitrum deployment: 0x18616C0a8389A2cabF596f91D3e6CCC626E58997
        console.log("Deploying InterestRateModel...");
        InterestRateModel interestRateModel = new InterestRateModel(
            0,                          // Base rate: 0%
            2398076729557582000,       // Multiplier: exact value to match Arbitrum (75990465991 * 31557600)
            36893488147411124000,      // Jump multiplier: exact value to match Arbitrum (1169084092181 * 31557600)  
            15679732462653118874       // Kink: exact value to match Arbitrum
        );
        console.log("InterestRateModel deployed at:", address(interestRateModel));

        // Deploy Oracle
        console.log("Deploying V3Oracle...");
        V3Oracle oracle = new V3Oracle(NPM, address(WETH), address(0));
        console.log("V3Oracle deployed at:", address(oracle));
        
        // Configure Oracle with reasonable settings
        oracle.setMaxPoolPriceDifference(200); // 2% max divergence

        // Configure WETH (reference token - like Arbitrum)
        oracle.setTokenConfig(
            WETH,
            ETH_USD_FEED,
            3600,                      // 1 hour heartbeat
            IUniswapV3Pool(address(0)), // No pool needed for reference token
            0,
            V3Oracle.Mode.TWAP,        // Use TWAP only for reference token (like Arbitrum)
            0
        );

        // Configure USDC
        oracle.setTokenConfig(
            USDC,
            USDC_USD_FEED,
            86400,                     // 24 hours heartbeat
            IUniswapV3Pool(USDC_ETH_005),
            60,                        // 1 minute TWAP
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200                        // 2% max divergence
        );

        // Configure DAI
        oracle.setTokenConfig(
            DAI,
            DAI_USD_FEED,
            3600,
            IUniswapV3Pool(DAI_ETH_030),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            100                        // 1% max divergence (stablecoin)
        );

        // Configure USDT
        oracle.setTokenConfig(
            USDT,
            USDT_USD_FEED,
            3600,
            IUniswapV3Pool(USDT_ETH_030),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200                        // 2% max divergence
        );

        // Configure WBTC
        oracle.setTokenConfig(
            WBTC,
            BTC_USD_FEED,
            3600,
            IUniswapV3Pool(WBTC_ETH_030),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200                        // 2% max divergence
        );

        // Deploy V3Vault
        console.log("Deploying V3Vault...");
        V3Vault vault = new V3Vault(
            "Revert Lend Mainnet USDC",
            "rlMainUSDC",
            address(USDC),
            NPM,
            interestRateModel,
            oracle,
            IPermit2(PERMIT2)
        );
        console.log("V3Vault deployed at:", address(vault));

        // Configure collateral factors (conservative for mainnet)
        vault.setTokenConfig(USDC, uint32(Q32 * 90 / 100), uint32(2**32-1));  // 90% CF, unlimited collateral value
        vault.setTokenConfig(WETH, uint32(Q32 * 85 / 100), uint32(2**32-1));  // 85% CF, unlimited collateral value  
        vault.setTokenConfig(DAI,  uint32(Q32 * 88 / 100), uint32(2**32-1));  // 88% CF, unlimited collateral value
        vault.setTokenConfig(USDT, uint32(Q32 * 85 / 100), uint32(Q32 * 25 / 100)); // 85% CF, max 25% collateral value
        vault.setTokenConfig(WBTC, uint32(Q32 * 80 / 100), uint32(2**32-1));  // 80% CF, unlimited collateral value

        // Set conservative limits for mainnet launch
        vault.setLimits(
            100000000,         // Min loan size: $100 USDC
            10000000000000,    // Global lend limit: $10,000,000 USDC
            80000000000000,     // Global debt limit: $80,000,000 USDC  
            2000000000000,     // Daily lend increase limit min: $2,000,000 USDC
            2000000000000      // Daily debt increase limit min: $2,000,000 USDC
        );

        // Set reserve factor (10% of interest goes to reserves)
        vault.setReserveFactor(uint32(Q32 * 10 / 100));
        
        // Set reserve protection (5% of lent amount must stay as reserves)
        vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100));


       

        // Deploy auxiliary contracts
        console.log("Deploying FlashloanLiquidator...");
        FlashloanLiquidator liquidator = new FlashloanLiquidator(NPM, EX0x, UNIVERSAL_ROUTER);
        console.log("FlashloanLiquidator deployed at:", address(liquidator));

        vm.stopBroadcast();

        // Print deployment summary
        console.log("\n=== MAINNET DEPLOYMENT COMPLETE ===");
        console.log("InterestRateModel:", address(interestRateModel));
        console.log("V3Oracle:", address(oracle));
        console.log("V3Vault:", address(vault));
        console.log("FlashloanLiquidator:", address(liquidator));
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Verify contracts on Etherscan");
        console.log("2. Test deposit/borrow with small amounts");
        console.log("3. Configure transformers (V3Utils, etc.)");
        console.log("4. Gradually increase limits based on usage");
    }
} 