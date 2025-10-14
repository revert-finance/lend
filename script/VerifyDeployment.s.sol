// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract VerifyDeployment is Script {
    // Color helper functions
    function red(string memory text) internal pure returns (string memory) {
        return string(abi.encodePacked("\u001b[91m", text, "\u001b[0m"));
    }
    
    function green(string memory text) internal pure returns (string memory) {
        return string(abi.encodePacked("\u001b[92m", text, "\u001b[0m"));
    }

    // Network configuration struct
    struct NetworkConfig {
        address interestRateModel;
        address v3Oracle;
        address v3Vault;
        address flashloanLiquidator;
        address expectedOwner;
        address v3Utils;
        address autoRange;
        address autoCompound;
        address autoExit;
        address leverageTransformer;
        address weth;
        address usdc;
        string networkName;
        // Interest Rate Model parameters per network
        uint64 expectedBaseRatePerSecondX64;
        uint64 expectedMultiplierPerSecondX64;
        uint64 expectedJumpMultiplierPerSecondX64;
        uint64 expectedKinkX64;
    }
    
    // Network configurations
    NetworkConfig private config;
    
    function run() external virtual {
        // Default to mainnet, but allow other networks to be called directly
        runMainnet();
    }
    
    function runMainnet() public {
        config = loadMainnetConfig();
        executeVerification();
    }
    
    function runArbitrum() public {
        config = loadArbitrumConfig();  
        executeVerification();
    }

    function runBase() public {
        config = loadBaseConfig();
        executeVerification();
    }
    
    function executeVerification() internal {
        console.log("=== REVERT LEND", config.networkName, "DEPLOYMENT VERIFICATION ===");
        console.log("");
        
        verifyContractAddresses();
        verifyOwnership();
        verifyInterestRateModel();
        verifyIntegration();
        verifyTransformerConfiguration();
        verifyBasicFunctionality();
        verifyVaultLimits();

        console.log("");
        console.log("=== VERIFICATION COMPLETE ===");
        console.log("Review all outputs above for any issues");
    }
    
    function loadMainnetConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig({
            // Mainnet addresses from latest deployment
            interestRateModel: 0xb50daFe03fEe68595Ab2bAaD3c16F899421F063B,
            v3Oracle: 0xe0151d335A6C4AB0600Ae4000a9CAAf7b236072f,
            v3Vault: 0xa2754543f69dC036764bBfad16d2A74F5cD15667,
            flashloanLiquidator: 0xa44080F20464de260e25F35A69d6BDa50f2cc79D,
            expectedOwner: 0xaac25e85e752425Dd1A92674CEeAF603758D3124,
            v3Utils: 0xAb52F8C11E72d00d4f717A657378Ef9b8bF7c2B6,
            autoRange: 0x88481E2Fbc98d4a251655B0F1A4422555EA72d9E,
            autoCompound: 0x7C81247aE0A35B03e3f4A704DCD6b101dcA53Abd,
            autoExit: 0xef4868D67a6dc9f0eb9dBaAdfaE6f4e78829Edf7,
            leverageTransformer: 0xbAEA7f73569456096fCf38AE34242c52CA227b1e,
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            networkName: "MAINNET",
            // Mainnet IRM parameters (90% kink, 300% jump)
            expectedBaseRatePerSecondX64: 0,
            expectedMultiplierPerSecondX64: 75990465991, // 12% APR
            expectedJumpMultiplierPerSecondX64: 1753626138271, // 300% APR
            expectedKinkX64: 16602069666338596454 // 90% in Q64
        });
    }
    
    function loadArbitrumConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig({
            interestRateModel: 0x18616C0a8389A2cabF596f91D3e6CCC626E58997,
            v3Oracle: 0x9F703BFccd04389725FbaD7Bc50F2E345583d506,
            v3Vault: 0x74E6AFeF5705BEb126C6d3Bf46f8fad8F3e07825,
            flashloanLiquidator: 0x5b94D444dfBa48780524A1F0Cd116F8A57BfEFc2,
            expectedOwner: 0x199B7d994c9d3A26ff81E93bdB5dBc780363F330, // TimeLockController
            v3Utils: 0x511CEbFAFd4cbd364D643B1B7eDFA5d6dD831349,
            autoRange: 0x5ff2195BA28d2544AeD91e30e5f74B87d4F158dE,
            autoCompound: 0x9D97c76102E72883CD25Fa60E0f4143516d5b6db,
            autoExit: 0xd0186335F7b7c390B6D6C0C021212243eD297DDA,
            leverageTransformer: 0xE5047B321071b939d48Ae8Aa34770C9838bb25e8,
            weth: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, // WETH on Arbitrum
            usdc: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC on Arbitrum
            networkName: "ARBITRUM",
            // Arbitrum IRM parameters (85% kink, 200% jump)
            expectedBaseRatePerSecondX64: 0,
            expectedMultiplierPerSecondX64: 75990465991, // 12% APR
            expectedJumpMultiplierPerSecondX64: 1169084092181, // 200% APR
            expectedKinkX64: 15679732462653118874 // 85% in Q64
        });
    }
    
    function loadBaseConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig({
            // Base V2 addresses from latest deployment
            interestRateModel: 0xD0524a77C8E2bD22b1F57268fD6beA1973aC7927,
            v3Oracle: 0x31c8Ae1E4d7a1788536aC19C92Ce3eBae3F4731F,
            v3Vault: 0x36AEAe0E411a1E28372e0d66f02E57744EbE7599,
            flashloanLiquidator: 0x6BCB1Ae7b3aec6086066dC4348dc679C93eeAC5b,
            expectedOwner: 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9,
            v3Utils: 0x98eC492942090364AC0736Ef1A741AE6C92ec790,
            autoRange: 0xA8549424B20a514Eb9e7a829ec013065Bef9Dc1D,
            autoCompound: 0x0bF485Bd7EbB82e282F72E7d14822C680E3f7bEC,
            autoExit: 0x16E0b91cE6F1c426df6e2A5a295D113e8f596A93,
            leverageTransformer: 0x5e97A478184993D3E376eec00B603F80463D9B23,
            weth: 0x4200000000000000000000000000000000000006, // WETH on Base
            usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC on Base
            networkName: "BASE",
            // Base IRM parameters (90% kink, 300% jump)
            expectedBaseRatePerSecondX64: 0,
            expectedMultiplierPerSecondX64: 75990465991, // 12% APR
            expectedJumpMultiplierPerSecondX64: 1753626138271, // 300% APR
            expectedKinkX64: 16602069666338596454 // 90% in Q64
        });
    }
    
    function verifyContractAddresses() internal view {
        console.log("1. DEPLOYED CONTRACT ADDRESSES");
        console.log("==============================");
        console.log("InterestRateModel:");
        console.logAddress(config.interestRateModel);
        console.log("V3Oracle:");
        console.logAddress(config.v3Oracle);
        console.log("V3Vault:");
        console.logAddress(config.v3Vault);
        console.log("FlashloanLiquidator:");
        console.logAddress(config.flashloanLiquidator);
        console.log("");
    }
    
    function verifyOwnership() internal view {
        console.log("2. OWNERSHIP VERIFICATION");
        console.log("========================");
        console.log("Checking ownership for all Ownable contracts:");
        console.log("-------------------------------------------");
        
        // Check core contracts (these should always exist)
        checkOwnership("V3Vault", config.v3Vault);
        checkOwnership("V3Oracle", config.v3Oracle);
        checkOwnership("InterestRateModel", config.interestRateModel);
        
        // Check transformers (these might not be deployed yet)
        console.log("\nChecking transformer ownership (if deployed):");
        console.log("-------------------------------------------");
        
        // V3Utils
        if (isContract(config.v3Utils)) {
            checkOwnership("V3Utils", config.v3Utils);
        } else {
            console.log("V3Utils: Not deployed yet");
        }
        
        // AutoRange
        if (isContract(config.autoRange)) {
            checkOwnership("AutoRange", config.autoRange);
        } else {
            console.log("AutoRange: Not deployed yet");
        }
        
        // AutoCompound
        if (isContract(config.autoCompound)) {
            checkOwnership("AutoCompound", config.autoCompound);
        } else {
            console.log("AutoCompound: Not deployed yet");
        }
        
        // AutoExit
        if (isContract(config.autoExit)) {
            checkOwnership("AutoExit", config.autoExit);
        } else {
            console.log("AutoExit: Not deployed yet");
        }
        
        // LeverageTransformer
        if (isContract(config.leverageTransformer)) {
            checkOwnership("LeverageTransformer", config.leverageTransformer);
        } else {
            console.log("LeverageTransformer: Not deployed yet");
        }
        
        console.log("");
    }
    
    // Helper function to check if an address is a contract
    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
    
    function verifyInterestRateModel() internal {
        console.log("3. INTEREST RATE MODEL VERIFICATION");
        console.log("==================================");
        
        uint64 actualBaseRate;
        uint64 actualMultiplier;
        uint64 actualJumpMultiplier;
        uint64 actualKink;
        
        // Get all values first
        (bool success, bytes memory data) = config.interestRateModel.staticcall(
            abi.encodeWithSignature("baseRatePerSecondX64()")
        );
        if (success) {
            actualBaseRate = abi.decode(data, (uint64));
        }
        
        (success, data) = config.interestRateModel.staticcall(
            abi.encodeWithSignature("multiplierPerSecondX64()")
        );
        if (success) {
            actualMultiplier = abi.decode(data, (uint64));
        }
        
        (success, data) = config.interestRateModel.staticcall(
            abi.encodeWithSignature("jumpMultiplierPerSecondX64()")
        );
        if (success) {
            actualJumpMultiplier = abi.decode(data, (uint64));
        }
        
        (success, data) = config.interestRateModel.staticcall(
            abi.encodeWithSignature("kinkX64()")
        );
        if (success) {
            actualKink = abi.decode(data, (uint64));
        }
        
        // Print results with actual values using vm.toString()
        console.log("BASE RATE PER SECOND X64:");
        console.log("  Expected:", vm.toString(config.expectedBaseRatePerSecondX64));
        console.log("  Actual:  ", vm.toString(actualBaseRate));
        console.log("  Status:  ", actualBaseRate == config.expectedBaseRatePerSecondX64 ? green("PASS") : red("FAIL"));
        console.log("  APR:     ~", convertX64ToAnnualPercent(actualBaseRate), "%");
        console.log("");
        
        console.log("MULTIPLIER PER SECOND X64:");
        console.log("  Expected:", vm.toString(config.expectedMultiplierPerSecondX64));
        console.log("  Actual:  ", vm.toString(actualMultiplier));
        console.log("  Status:  ", actualMultiplier == config.expectedMultiplierPerSecondX64 ? green("PASS") : red("FAIL"));
        console.log("  APR:     ~", convertX64ToAnnualPercent(actualMultiplier), "%");
        console.log("");
        
        console.log("JUMP MULTIPLIER PER SECOND X64:");
        console.log("  Expected:", vm.toString(config.expectedJumpMultiplierPerSecondX64));
        console.log("  Actual:  ", vm.toString(actualJumpMultiplier));
        console.log("  Status:  ", actualJumpMultiplier == config.expectedJumpMultiplierPerSecondX64 ? green("PASS") : red("FAIL"));
        console.log("  APR:     ~", convertX64ToAnnualPercent(actualJumpMultiplier), "%");
        console.log("");
        
        console.log("KINK X64:");
        console.log("  Expected:", vm.toString(config.expectedKinkX64));
        console.log("  Actual:  ", vm.toString(actualKink));
        console.log("  Status:  ", actualKink == config.expectedKinkX64 ? green("PASS") : red("FAIL"));
        console.log("  Percent:  ~", convertX64ToPercent(actualKink), "%");
        
        console.log("");
    }
    
    // Convert X64 rate to annual percentage (approximate)
    function convertX64ToAnnualPercent(uint64 rateX64) internal pure returns (uint256) {
        // Seconds per year: 365.25 * 24 * 3600 = 31557600
        // Convert: (rateX64 / 2^64) * 31557600 * 100
        // Simplified: rateX64 * 31557600 * 100 / 2^64
        return (uint256(rateX64) * 31557600 * 100) >> 64;
    }
    
    // Convert X64 to percentage
    function convertX64ToPercent(uint64 valueX64) internal pure returns (uint256) {
        // Convert: (valueX64 / 2^64) * 100
        return (uint256(valueX64) * 100) >> 64;
    }

    // Format token amount with proper decimals and commas
    function formatTokenAmount(uint256 amount, uint8 decimals) internal pure returns (string memory) {
        if (amount == 0) return "0";

        uint256 divisor = 10 ** uint256(decimals);
        uint256 wholePart = amount / divisor;
        uint256 fractionalPart = amount % divisor;

        // Format whole part with commas
        string memory wholePartFormatted = formatWithCommas(wholePart);

        // Simple formatting - just show whole part and up to 2 decimal places
        if (fractionalPart == 0) {
            return wholePartFormatted;
        }

        // Scale down fractional part to 2 decimal places
        uint256 scaledFraction = (fractionalPart * 100) / divisor;

        return string(abi.encodePacked(
            wholePartFormatted,
            ".",
            scaledFraction < 10 ? "0" : "",
            uintToString(scaledFraction)
        ));
    }

    // Format number with commas for thousands separators
    function formatWithCommas(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        // First convert to string without commas
        string memory numStr = uintToString(value);
        bytes memory numBytes = bytes(numStr);
        uint256 len = numBytes.length;

        // Calculate how many commas we need
        uint256 commas = len > 3 ? (len - 1) / 3 : 0;

        // Create new array with space for commas
        bytes memory result = new bytes(len + commas);

        uint256 j = result.length;
        uint256 digitCount = 0;

        // Build string from right to left, adding commas every 3 digits
        for (uint256 i = len; i > 0; i--) {
            if (digitCount == 3) {
                j--;
                result[j] = ',';
                digitCount = 0;
            }
            j--;
            result[j] = numBytes[i - 1];
            digitCount++;
        }

        return string(result);
    }

    // Helper to convert uint to string
    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function verifyIntegration() internal view {
        console.log("4. INTEGRATION VERIFICATION");
        console.log("===========================");
        
        // Check V3Vault oracle reference
        (bool success, bytes memory data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("oracle()")
        );
        if (success) {
            address vaultOracle = abi.decode(data, (address));
            console.log("V3Vault Oracle Reference:");
            console.log("  Expected:");
            console.logAddress(config.v3Oracle);
            console.log("  Actual:");
            console.logAddress(vaultOracle);
            if (vaultOracle == config.v3Oracle) {
                console.log("  Match:   ", green("PASS"));
            } else {
                console.log("  Match:   ", red("FAIL - ORACLE MISMATCH!"));
            }
        } else {
            console.log(red("FAIL - V3Vault Oracle Reference: FAILED TO CHECK"));
        }
        
        // Check V3Vault interest rate model reference
        (success, data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("interestRateModel()")
        );
        if (success) {
            address vaultIRM = abi.decode(data, (address));
            console.log("V3Vault IRM Reference:");
            console.log("  Expected:");
            console.logAddress(config.interestRateModel);
            console.log("  Actual:");
            console.logAddress(vaultIRM);
            if (vaultIRM == config.interestRateModel) {
                console.log("  Match:   ", green("PASS"));
            } else {
                console.log("  Match:   ", red("FAIL - IRM MISMATCH!"));
            }
        } else {
            console.log(red("FAIL - V3Vault IRM Reference: FAILED TO CHECK"));
        }
        
        // Check Oracle reference token
        (success, data) = config.v3Oracle.staticcall(
            abi.encodeWithSignature("referenceToken()")
        );
        if (success) {
            address refToken = abi.decode(data, (address));
            console.log("Oracle Reference Token:");
            console.log("  Expected (WETH):");
            console.logAddress(config.weth);
            console.log("  Actual:");
            console.logAddress(refToken);
            if (refToken == config.weth) {
                console.log("  Match:   ", green("PASS"));
            } else {
                console.log("  Match:   ", red("FAIL - REFERENCE TOKEN MISMATCH!"));
            }
        } else {
            console.log(red("FAIL - Oracle Reference Token: FAILED TO CHECK"));
        }
        
        console.log("");
    }
    
    function verifyTransformerConfiguration() internal view {
        console.log("5. TRANSFORMER CONFIGURATION VERIFICATION");
        console.log("=======================================");
        
        // First, log all configured transformer addresses
        console.log("CONFIGURED TRANSFORMER ADDRESSES:");
        console.log("V3Utils:");
        console.logAddress(config.v3Utils);
        console.log("AutoRange:");
        console.logAddress(config.autoRange);
        console.log("AutoCompound:");
        console.logAddress(config.autoCompound);
        console.log("AutoExit:");
        console.logAddress(config.autoExit);
        console.log("LeverageTransformer:");
        console.logAddress(config.leverageTransformer);
        console.log("");
        
        console.log("VAULT AUTHORIZATION STATUS:");
        console.log("---------------------------");
        // Check if transformers are authorized by the vault
        checkTransformerAuthorization("V3Utils", config.v3Utils);
        checkTransformerAuthorization("AutoRange", config.autoRange);
        checkTransformerAuthorization("AutoCompound", config.autoCompound);
        checkTransformerAuthorization("LeverageTransformer", config.leverageTransformer);
        console.log("");
        
        console.log("TRANSFORMER VAULT CONFIGURATION:");
        console.log("--------------------------------");
        // Check if transformers have the vault configured
        checkTransformerVaultConfig("V3Utils", config.v3Utils);
        checkTransformerVaultConfig("AutoRange", config.autoRange);
        checkTransformerVaultConfig("AutoCompound", config.autoCompound);
        checkTransformerVaultConfig("LeverageTransformer", config.leverageTransformer);
        
        // AutoExit note
        console.log("AutoExit: Not a transformer (doesn't need vault configuration)");
        
        console.log("");
    }
    
    function verifyBasicFunctionality() internal view {
        console.log("6. BASIC FUNCTIONALITY CHECKS");
        console.log("=============================");
        
        // Check vault asset
        (bool success, bytes memory data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("asset()")
        );
        if (success) {
            address asset = abi.decode(data, (address));
            console.log("V3Vault Asset:");
            console.logAddress(asset);
            console.log("Expected (USDC):");
            console.logAddress(config.usdc);
            if (asset == config.usdc) {
                console.log("Match:", green("PASS"));
            } else {
                console.log("Match:", red("FAIL - ASSET MISMATCH!"));
            }
        } else {
            console.log(red("FAIL - V3Vault Asset: FAILED TO CHECK"));
        }
        
        // Check vault total supply
        (success, data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("totalSupply()")
        );
        if (success) {
            uint256 totalSupply = abi.decode(data, (uint256));
            console.log("V3Vault Total Supply:", totalSupply);
        } else {
            console.log("V3Vault Total Supply: FAILED TO CHECK");
        }
        
        // Check vault total assets
        (success, data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("totalAssets()")
        );
        if (success) {
            uint256 totalAssets = abi.decode(data, (uint256));
            console.log("V3Vault Total Assets:", totalAssets);
        } else {
            console.log("V3Vault Total Assets: FAILED TO CHECK");
        }
        
        console.log("");
    }
    
    function checkOwnership(string memory contractName, address contractAddr) internal view {
        (bool success, bytes memory data) = contractAddr.staticcall(
            abi.encodeWithSignature("owner()")
        );
        
        if (success) {
            address owner = abi.decode(data, (address));
            console.log("Owner check for:", contractName);
            console.log("  Expected:");
            console.logAddress(config.expectedOwner);
            console.log("  Actual:");
            console.logAddress(owner);
            
            if (owner == config.expectedOwner) {
                console.log("  Match:   ", green("PASS"));
            } else {
                console.log("  Match:   ", red("FAIL - OWNER MISMATCH!"));
            }
        } else {
            console.log(red("FAIL - Owner check FAILED for:"), contractName);
        }
    }

    function checkTransformerAuthorization(string memory transformerName, address transformerAddr) internal view {
        (bool success, bytes memory data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("transformerAllowList(address)", transformerAddr)
        );
        
        if (success) {
            bool isAuthorized = abi.decode(data, (bool));
            console.log("Vault authorization for:", transformerName);
            console.log("  Address:");
            console.logAddress(transformerAddr);
            if (isAuthorized) {
                console.log("  Authorized:", green("PASS"));
            } else {
                console.log("  Authorized:", red("FAIL - NOT AUTHORIZED!"));
            }
        } else {
            console.log(red("FAIL - Vault authorization check FAILED for:"), transformerName);
        }
    }

    function checkTransformerVaultConfig(string memory transformerName, address transformerAddr) internal view {
        (bool success, bytes memory data) = transformerAddr.staticcall(
            abi.encodeWithSignature("vaults(address)", config.v3Vault)
        );

        if (success) {
            bool isConfigured = abi.decode(data, (bool));
            console.log("Vault configuration for:", transformerName);
            console.log("  Vault Address:");
            console.logAddress(config.v3Vault);
            if (isConfigured) {
                console.log("  Configured:  ", green("PASS"));
            } else {
                console.log("  Configured:  ", red("FAIL - NOT CONFIGURED!"));
            }
        } else {
            console.log(red("FAIL - Vault configuration check FAILED for:"), transformerName);
        }
    }

    function verifyVaultLimits() internal {
        console.log("7. VAULT LIMITS VERIFICATION");
        console.log("============================");

        // Get asset decimals first
        uint8 decimals = 6; // Default to 6 for USDC
        (bool success, bytes memory data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (success) {
            decimals = abi.decode(data, (uint8));
        }

        // Get the asset symbol for display
        string memory assetSymbol = "USDC"; // Default
        (success, data) = config.usdc.staticcall(
            abi.encodeWithSignature("symbol()")
        );
        if (success) {
            assetSymbol = abi.decode(data, (string));
        }

        // MIN LOAN SIZE
        console.log("MIN LOAN SIZE:");
        (success, data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("minLoanSize()")
        );
        if (success) {
            uint256 minLoanSize = abi.decode(data, (uint256));
            console.log("  Raw Value:   ", formatWithCommas(minLoanSize));
            console.log("  Formatted:   ", formatTokenAmount(minLoanSize, decimals), assetSymbol);
        } else {
            console.log(red("  FAILED TO READ"));
        }
        console.log("");

        // GLOBAL LEND LIMIT
        console.log("GLOBAL LEND LIMIT:");
        (success, data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("globalLendLimit()")
        );
        if (success) {
            uint256 globalLendLimit = abi.decode(data, (uint256));
            console.log("  Raw Value:   ", formatWithCommas(globalLendLimit));
            if (globalLendLimit == type(uint256).max) {
                console.log("  Formatted:    UNLIMITED");
            } else {
                console.log("  Formatted:   ", formatTokenAmount(globalLendLimit, decimals), assetSymbol);
            }
        } else {
            console.log(red("  FAILED TO READ"));
        }
        console.log("");

        // GLOBAL DEBT LIMIT
        console.log("GLOBAL DEBT LIMIT:");
        (success, data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("globalDebtLimit()")
        );
        if (success) {
            uint256 globalDebtLimit = abi.decode(data, (uint256));
            console.log("  Raw Value:   ", formatWithCommas(globalDebtLimit));
            if (globalDebtLimit == type(uint256).max) {
                console.log("  Formatted:    UNLIMITED");
            } else {
                console.log("  Formatted:   ", formatTokenAmount(globalDebtLimit, decimals), assetSymbol);
            }
        } else {
            console.log(red("  FAILED TO READ"));
        }
        console.log("");

        // DAILY LEND INCREASE LIMIT (MIN)
        console.log("DAILY LEND INCREASE LIMIT (MIN):");
        (success, data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("dailyLendIncreaseLimitMin()")
        );
        if (success) {
            uint256 dailyLendIncreaseLimitMin = abi.decode(data, (uint256));
            console.log("  Raw Value:   ", formatWithCommas(dailyLendIncreaseLimitMin));
            if (dailyLendIncreaseLimitMin == type(uint256).max) {
                console.log("  Formatted:    UNLIMITED");
            } else {
                console.log("  Formatted:   ", formatTokenAmount(dailyLendIncreaseLimitMin, decimals), assetSymbol);
            }

            // Also show current left amount
            (bool successLeft, bytes memory dataLeft) = config.v3Vault.staticcall(
                abi.encodeWithSignature("dailyLendIncreaseLimitLeft()")
            );
            if (successLeft) {
                uint256 dailyLendIncreaseLimitLeft = abi.decode(dataLeft, (uint256));
                console.log("  Current Left:", formatTokenAmount(dailyLendIncreaseLimitLeft, decimals), assetSymbol);
            }
        } else {
            console.log(red("  FAILED TO READ"));
        }
        console.log("");

        // DAILY DEBT INCREASE LIMIT (MIN)
        console.log("DAILY DEBT INCREASE LIMIT (MIN):");
        (success, data) = config.v3Vault.staticcall(
            abi.encodeWithSignature("dailyDebtIncreaseLimitMin()")
        );
        if (success) {
            uint256 dailyDebtIncreaseLimitMin = abi.decode(data, (uint256));
            console.log("  Raw Value:   ", formatWithCommas(dailyDebtIncreaseLimitMin));
            if (dailyDebtIncreaseLimitMin == type(uint256).max) {
                console.log("  Formatted:    UNLIMITED");
            } else {
                console.log("  Formatted:   ", formatTokenAmount(dailyDebtIncreaseLimitMin, decimals), assetSymbol);
            }

            // Also show current left amount
            (bool successLeft, bytes memory dataLeft) = config.v3Vault.staticcall(
                abi.encodeWithSignature("dailyDebtIncreaseLimitLeft()")
            );
            if (successLeft) {
                uint256 dailyDebtIncreaseLimitLeft = abi.decode(dataLeft, (uint256));
                console.log("  Current Left:", formatTokenAmount(dailyDebtIncreaseLimitLeft, decimals), assetSymbol);
            }
        } else {
            console.log(red("  FAILED TO READ"));
        }
        console.log("");
    }
} 