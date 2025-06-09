// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract VerifyDeployment is Script {
    // Deployed contract addresses on Mainnet
    address constant INTEREST_RATE_MODEL = 0x8Bccb779bd4cd1b68dea65936E99BB1c08480279;
    address constant V3_ORACLE = 0xda0f97EF9E906a0E35b8A2DC0715898f56A98a30;
    address constant V3_VAULT = 0x68e7cBf0072dfDf9dA73058f04e3237766dD0aDB;
    address constant FLASHLOAN_LIQUIDATOR = 0x1CB0B8a5671B9a4d3D38ed99C049A105922Aed57;
    
    // Expected deployer
    address constant EXPECTED_OWNER = 0x3895e33b91f19B279D30B1436640c87E300D2DAc;
    
    // Expected values from deployed contract (X64 format) - actual deployed values
    uint64 constant EXPECTED_BASE_RATE_PER_SECOND_X64 = 0;
    uint64 constant EXPECTED_MULTIPLIER_PER_SECOND_X64 = 75990465991;
    uint64 constant EXPECTED_JUMP_MULTIPLIER_PER_SECOND_X64 = 1169084092180;
    uint64 constant EXPECTED_KINK_X64 = 15679732462653118874; // 85% in Q64
    
    // Important addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function run() external view {
        console.log("=== REVERT LEND MAINNET DEPLOYMENT VERIFICATION ===");
        console.log("");
        
        verifyContractAddresses();
        verifyOwnership();
        verifyInterestRateModel();
        verifyIntegration();
        verifyBasicFunctionality();
        
        console.log("");
        console.log("=== VERIFICATION COMPLETE ===");
        console.log("Review all outputs above for any issues");
    }
    
    function verifyContractAddresses() internal view {
        console.log("1. DEPLOYED CONTRACT ADDRESSES");
        console.log("==============================");
        console.log("InterestRateModel:");
        console.logAddress(INTEREST_RATE_MODEL);
        console.log("V3Oracle:");
        console.logAddress(V3_ORACLE);
        console.log("V3Vault:");
        console.logAddress(V3_VAULT);
        console.log("FlashloanLiquidator:");
        console.logAddress(FLASHLOAN_LIQUIDATOR);
        console.log("");
    }
    
    function verifyOwnership() internal view {
        console.log("2. OWNERSHIP VERIFICATION");
        console.log("========================");
        
        checkOwnership("V3Vault", V3_VAULT);
        checkOwnership("V3Oracle", V3_ORACLE);
        checkOwnership("InterestRateModel", INTEREST_RATE_MODEL);
        
        // FlashloanLiquidator doesn't inherit from Ownable
        console.log("FlashloanLiquidator: Not an Ownable contract (no owner function)");
        
        console.log("");
    }
    
    function verifyInterestRateModel() internal view {
        console.log("3. INTEREST RATE MODEL VERIFICATION");
        console.log("==================================");
        
        // Get Interest Rate Model parameters using correct function names
        (bool success, bytes memory data) = INTEREST_RATE_MODEL.staticcall(
            abi.encodeWithSignature("baseRatePerSecondX64()")
        );
        if (success) {
            uint64 baseRate = abi.decode(data, (uint64));
            console.log("Base Rate Per Second X64:");
            console.log("  Expected:", EXPECTED_BASE_RATE_PER_SECOND_X64);
            console.log("  Actual:  ", baseRate);
            console.log("  Match:   ", baseRate == EXPECTED_BASE_RATE_PER_SECOND_X64);
        } else {
            console.log("Base Rate Per Second X64: FAILED TO CHECK");
        }
        
        (success, data) = INTEREST_RATE_MODEL.staticcall(
            abi.encodeWithSignature("multiplierPerSecondX64()")
        );
        if (success) {
            uint64 multiplier = abi.decode(data, (uint64));
            console.log("Multiplier Per Second X64:");
            console.log("  Expected:", EXPECTED_MULTIPLIER_PER_SECOND_X64);
            console.log("  Actual:  ", multiplier);
            console.log("  Match:   ", multiplier == EXPECTED_MULTIPLIER_PER_SECOND_X64);
        } else {
            console.log("Multiplier Per Second X64: FAILED TO CHECK");
        }
        
        (success, data) = INTEREST_RATE_MODEL.staticcall(
            abi.encodeWithSignature("jumpMultiplierPerSecondX64()")
        );
        if (success) {
            uint64 jumpMultiplier = abi.decode(data, (uint64));
            console.log("Jump Multiplier Per Second X64:");
            console.log("  Expected:", EXPECTED_JUMP_MULTIPLIER_PER_SECOND_X64);
            console.log("  Actual:  ", jumpMultiplier);
            console.log("  Match:   ", jumpMultiplier == EXPECTED_JUMP_MULTIPLIER_PER_SECOND_X64);
        } else {
            console.log("Jump Multiplier Per Second X64: FAILED TO CHECK");
        }
        
        (success, data) = INTEREST_RATE_MODEL.staticcall(
            abi.encodeWithSignature("kinkX64()")
        );
        if (success) {
            uint64 kink = abi.decode(data, (uint64));
            console.log("Kink X64:");
            console.log("  Expected:", EXPECTED_KINK_X64);
            console.log("  Actual:  ", kink);
            console.log("  Match:   ", kink == EXPECTED_KINK_X64);
        } else {
            console.log("Kink X64: FAILED TO CHECK");
        }
        
        // Show human-readable percentages
        console.log("");
        console.log("Human-readable rates (approximate):");
        console.log("  Base Rate Per Year: 0%");
        console.log("  Multiplier Per Year: 13%");
        console.log("  Jump Multiplier Per Year: 200%");
        console.log("  Kink: 85%");
        
        console.log("");
    }
    
    function verifyIntegration() internal view {
        console.log("4. INTEGRATION VERIFICATION");
        console.log("===========================");
        
        // Check V3Vault oracle reference
        (bool success, bytes memory data) = V3_VAULT.staticcall(
            abi.encodeWithSignature("oracle()")
        );
        if (success) {
            address vaultOracle = abi.decode(data, (address));
            console.log("V3Vault Oracle Reference:");
            console.log("  Expected:");
            console.logAddress(V3_ORACLE);
            console.log("  Actual:");
            console.logAddress(vaultOracle);
            console.log("  Match:   ", vaultOracle == V3_ORACLE);
        } else {
            console.log("V3Vault Oracle Reference: FAILED TO CHECK");
        }
        
        // Check V3Vault interest rate model reference
        (success, data) = V3_VAULT.staticcall(
            abi.encodeWithSignature("interestRateModel()")
        );
        if (success) {
            address vaultIRM = abi.decode(data, (address));
            console.log("V3Vault IRM Reference:");
            console.log("  Expected:");
            console.logAddress(INTEREST_RATE_MODEL);
            console.log("  Actual:");
            console.logAddress(vaultIRM);
            console.log("  Match:   ", vaultIRM == INTEREST_RATE_MODEL);
        } else {
            console.log("V3Vault IRM Reference: FAILED TO CHECK");
        }
        
        // Check Oracle reference token
        (success, data) = V3_ORACLE.staticcall(
            abi.encodeWithSignature("referenceToken()")
        );
        if (success) {
            address refToken = abi.decode(data, (address));
            console.log("Oracle Reference Token:");
            console.log("  Expected (WETH):");
            console.logAddress(WETH);
            console.log("  Actual:");
            console.logAddress(refToken);
            console.log("  Match:   ", refToken == WETH);
        } else {
            console.log("Oracle Reference Token: FAILED TO CHECK");
        }
        
        console.log("");
    }
    
    function verifyBasicFunctionality() internal view {
        console.log("5. BASIC FUNCTIONALITY CHECKS");
        console.log("=============================");
        
        // Check vault asset
        (bool success, bytes memory data) = V3_VAULT.staticcall(
            abi.encodeWithSignature("asset()")
        );
        if (success) {
            address asset = abi.decode(data, (address));
            console.log("V3Vault Asset:");
            console.logAddress(asset);
            console.log("Expected (USDC):");
            console.logAddress(USDC);
            console.log("Match:", asset == USDC);
        } else {
            console.log("V3Vault Asset: FAILED TO CHECK");
        }
        
        // Check vault total supply
        (success, data) = V3_VAULT.staticcall(
            abi.encodeWithSignature("totalSupply()")
        );
        if (success) {
            uint256 totalSupply = abi.decode(data, (uint256));
            console.log("V3Vault Total Supply:", totalSupply);
        } else {
            console.log("V3Vault Total Supply: FAILED TO CHECK");
        }
        
        // Check vault total assets
        (success, data) = V3_VAULT.staticcall(
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
            console.logAddress(EXPECTED_OWNER);
            console.log("  Actual:");
            console.logAddress(owner);
            console.log("  Match:   ", owner == EXPECTED_OWNER);
        } else {
            console.log("Owner check FAILED for:", contractName);
        }
    }
} 