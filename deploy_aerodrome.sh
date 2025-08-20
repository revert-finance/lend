#!/bin/bash

# Aerodrome Protocol Deployment Script for Base Mainnet

echo "==========================================="
echo "AERODROME PROTOCOL DEPLOYMENT - BASE"
echo "==========================================="

# Check for required environment variables
if [ -z "$ETH_RPC_URL" ]; then
    echo "Error: ETH_RPC_URL not set"
    echo "Please set: export ETH_RPC_URL=https://rpc.ankr.com/base"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY not set"
    echo "Please set: export PRIVATE_KEY=your_private_key_here"
    exit 1
fi

if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo "Warning: ETHERSCAN_API_KEY not set"
    echo "Contracts will deploy but won't be verified"
    echo "Set with: export ETHERSCAN_API_KEY=your_api_key"
fi

# Step 1: Clean and build
echo ""
echo "Step 1: Cleaning and building contracts..."
forge clean
forge build

# Check contract sizes
echo ""
echo "Checking contract sizes..."
forge build --sizes | grep -E "Contract|V3Vault|GaugeManager|─────"

# Confirm V3Vault is under limit
V3VAULT_SIZE=$(forge build --sizes | grep "V3Vault" | awk '{print $2}' | tr -d ',')
if [ "$V3VAULT_SIZE" -gt 24576 ]; then
    echo "Error: V3Vault size ($V3VAULT_SIZE) exceeds limit (24576)"
    echo "Please optimize the contract before deployment"
    exit 1
fi
echo "V3Vault size OK: $V3VAULT_SIZE bytes"

# Step 2: Deploy contracts
echo ""
echo "Step 2: Deploying contracts..."
echo "This will deploy:"
echo "  - V3Oracle"
echo "  - InterestRateModel"
echo "  - V3Vault"
echo "  - GaugeManager"
echo "  - LeverageTransformer"
echo ""
read -p "Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit 1
fi

# Run deployment
if [ -z "$ETHERSCAN_API_KEY" ]; then
    # Deploy without verification
    forge script script/DeployAerodromeProtocol.s.sol \
        --rpc-url $ETH_RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast \
        -vvv
else
    # Deploy with verification
    forge script script/DeployAerodromeProtocol.s.sol \
        --rpc-url $ETH_RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast \
        --verify \
        --etherscan-api-key $ETHERSCAN_API_KEY \
        -vvv
fi

# Check deployment status
if [ $? -eq 0 ]; then
    echo ""
    echo "==========================================="
    echo "DEPLOYMENT SUCCESSFUL!"
    echo "==========================================="
    echo ""
    echo "NEXT STEPS:"
    echo "1. Note the deployed contract addresses from the output above"
    echo "2. Get gauge addresses for pools from Aerodrome:"
    echo "   - WETH/USDC gauge"
    echo "   - cbBTC/USDC gauge"
    echo "   - Any other pools you want to support"
    echo ""
    echo "3. Update ConfigureGauges.s.sol with:"
    echo "   - Deployed GaugeManager address"
    echo "   - Deployed Vault address"
    echo "   - Gauge addresses from Aerodrome"
    echo ""
    echo "4. Run configuration:"
    echo "   forge script script/ConfigureGauges.s.sol --rpc-url \$ETH_RPC_URL --private-key \$PRIVATE_KEY --broadcast"
    echo ""
    echo "5. Transfer ownership to multi-sig"
    echo "6. Set emergency admin for vault"
    echo "7. Test with small transactions"
else
    echo ""
    echo "==========================================="
    echo "DEPLOYMENT FAILED!"
    echo "==========================================="
    echo "Please check the error messages above"
    exit 1
fi

