# Aerodrome Lending Protocol - Integration Guide

## Deployed Contracts on Base Mainnet

| Contract | Address | Basescan |
|----------|---------|----------|
| **V3Vault** | `0x0a9732DBF587e7c54C75D88919bF1e60AfA84D4B` | [View](https://basescan.org/address/0x0a9732DBF587e7c54C75D88919bF1e60AfA84D4B) |
| **V3Oracle** | `0xE865a28c24cDf7d79B5d42d78BC730DA8562C929` | [View](https://basescan.org/address/0xE865a28c24cDf7d79B5d42d78BC730DA8562C929) |
| **GaugeManager** | `0x6EEEE423297481Ce9e4e007E191e789eD3B4dA21` | [View](https://basescan.org/address/0x6EEEE423297481Ce9e4e007E191e789eD3B4dA21) |
| **LeverageTransformer** | `0xbB8Bc23D6866F39C0c180E67c9cf3ABa403c4286` | [View](https://basescan.org/address/0xbB8Bc23D6866F39C0c180E67c9cf3ABa403c4286) |
| **InterestRateModel** | `0x87D676f269cF19673F1bf258Ee2eBa2E64d0039E` | [View](https://basescan.org/address/0x87D676f269cF19673F1bf258Ee2eBa2E64d0039E) |
| **V3Utils** (existing) | `0x7D1F9FC22beD0798cDA3Fdb18b14a96fc838B9E1` | [View](https://basescan.org/address/0x7D1F9FC22beD0798cDA3Fdb18b14a96fc838B9E1) |

## Protocol Overview

The Aerodrome Lending Protocol enables users to:
- **Lend USDC** to earn interest (receive rlUSDC tokens)
- **Borrow USDC** against Aerodrome LP NFT positions
- **Stake positions** in Aerodrome gauges while borrowing
- **Compound AERO rewards** automatically (integrated in GaugeManager)
- **Leverage LP positions** using borrowed funds

## Core Contract Interfaces

### 1. V3Vault (rlUSDC)

The main vault contract for lending and borrowing operations.

```solidity
interface IV3Vault {
    // ERC20 Functions (for rlUSDC token)
    function name() external view returns (string memory); // "Revert Lend USDC"
    function symbol() external view returns (string memory); // "rlUSDC"
    function decimals() external view returns (uint8); // 6
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    
    // Lending Functions
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    
    // View Functions for Lending
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxMint(address) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    
    // NFT Collateral Functions
    function create(uint256 tokenId, address recipient) external returns (uint256 newTokenId);
    function createWithPermit(uint256 tokenId, address owner, address recipient, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256 newTokenId);
    function add(uint256 tokenId, address owner, address recipient, uint128 liquidity, uint256 amount0Min, uint256 amount1Min, uint256 deadline) external;
    function remove(uint256 tokenId, address recipient) external;
    
    // Borrowing Functions
    function borrow(uint256 tokenId, uint256 amount) external;
    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params) external returns (uint256 amount0, uint256 amount1);
    function repay(uint256 tokenId, uint256 amount, bool isShare) external;
    function liquidate(LiquidateParams calldata params) external;
    
    // Gauge Functions (for vaulted positions)
    function stakePosition(uint256 tokenId) external;
    function unstakePosition(uint256 tokenId) external;
    
    // View Functions for Positions
    function loans(uint256 tokenId) external view returns (uint256 debtShares);
    function loanInfo(uint256 tokenId) external view returns (uint256 debt, uint256 fullValue, uint256 collateralValue, uint256 availableToBorrow);
    function ownerOf(uint256 tokenId) external view returns (address);
    function lenderInfo(address account) external view returns (uint256 amount, uint256 debt, uint256 collateralValue);
    
    // Global State
    function globalLendAmount() external view returns (uint256);
    function globalDebtAmount() external view returns (uint256);
    function dailyLendIncreaseLimitLeft() external view returns (uint256);
    function dailyDebtIncreaseLimitLeft() external view returns (uint256);
}
```

### 2. GaugeManager

Manages staking of Aerodrome positions in gauges and integrated AERO compounding.

```solidity
interface IGaugeManager {
    // Staking Functions
    function stakePosition(uint256 tokenId) external;
    function unstakePosition(uint256 tokenId) external;
    
    // Reward Functions
    function claimRewards(uint256 tokenId) external;
    function compoundRewards(
        uint256 tokenId,
        bytes calldata swapData0,
        bytes calldata swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external;
    
    // Advanced V3Utils Integration
    function executeV3UtilsWithOptionalCompound(
        uint256 tokenId,
        address v3utils,
        IV3Utils.Instructions memory instructions,
        bool shouldCompound,
        bytes memory aeroSwapData0,
        bytes memory aeroSwapData1,
        uint256 minAeroAmount0,
        uint256 minAeroAmount1,
        uint256 aeroSplitBps
    ) external returns (uint256 newTokenId);
    
    // View Functions
    function tokenIdToGauge(uint256 tokenId) external view returns (address);
    function positionOwners(uint256 tokenId) external view returns (address);
    function poolToGauge(address pool) external view returns (address);
    
    // Admin Functions
    function setGauge(address pool, address gauge) external;
    function setOperator(address operator, bool active) external;
}
```

#### Function Parameters

**compoundRewards** - Compounds AERO rewards back into the position:
- `tokenId`: The staked position to compound rewards for
- `swapData0`: Swap calldata for AERO → token0 (from 0x API or router)
- `swapData1`: Swap calldata for AERO → token1 (from 0x API or router)
- `minAmount0`: Minimum amount of token0 expected from AERO swap (slippage protection)
- `minAmount1`: Minimum amount of token1 expected from AERO swap (slippage protection)
- `aeroSplitBps`: Basis points of AERO to swap to token0 (e.g., 5000 = 50%, rest goes to token1)
- `deadline`: Transaction deadline timestamp

**executeV3UtilsWithOptionalCompound** - Execute V3Utils operations on staked positions:
- `tokenId`: The staked position to operate on
- `v3utils`: Address of the V3Utils contract (0x7D1F9FC22beD0798cDA3Fdb18b14a96fc838B9E1)
- `instructions`: V3Utils instruction struct containing the operation details (see V3Utils docs)
- `shouldCompound`: Whether to compound AERO rewards before re-staking
- `aeroSwapData0`: Swap calldata for AERO → token0 (only used if shouldCompound=true)
- `aeroSwapData1`: Swap calldata for AERO → token1 (only used if shouldCompound=true)
- `minAeroAmount0`: Minimum token0 from AERO swap (only used if shouldCompound=true)
- `minAeroAmount1`: Minimum token1 from AERO swap (only used if shouldCompound=true)
- `aeroSplitBps`: Basis points of AERO to swap to token0 (only used if shouldCompound=true)

### 3. V3Oracle

Provides price feeds for collateral valuation.

```solidity
interface IV3Oracle {
    enum Mode {
        NOT_SET,
        CHAINLINK_TWAP_VERIFY,
        TWAP_CHAINLINK_VERIFY,
        CHAINLINK,
        TWAP
    }
    
    // Get position value
    function getValue(uint256 tokenId, address pool) external view returns (uint256 value0, uint256 value1);
    
    // Get token prices
    function getTokenPrice(address token) external view returns (uint256 priceX96);
    
    // Admin functions
    function setTokenConfig(address token, address feed, uint32 maxFeedAge, address pool, uint32 twapSeconds, Mode mode, uint16 maxDifference) external;
    function setMaxPoolPriceDifference(uint16 maxDifference) external;
}
```

## Integration Examples

### 1. Lending USDC

```solidity
// Approve USDC spending
IERC20(USDC).approve(V3_VAULT, amount);

// Deposit USDC, receive rlUSDC
uint256 shares = IV3Vault(V3_VAULT).deposit(amount, msg.sender);
```

### 2. Creating a Collateralized Position

```solidity
// First approve NFT transfer to vault
IAerodromeNPM(AERODROME_NPM).approve(V3_VAULT, tokenId);

// Create position in vault
uint256 vaultTokenId = IV3Vault(V3_VAULT).create(tokenId, msg.sender);

// Now you can borrow against it
IV3Vault(V3_VAULT).borrow(vaultTokenId, borrowAmount);
```

### 3. Staking Position in Gauge (Direct)

```solidity
// Approve GaugeManager to take NFT
IAerodromeNPM(AERODROME_NPM).approve(GAUGE_MANAGER, tokenId);

// Stake position
IGaugeManager(GAUGE_MANAGER).stakePosition(tokenId);

// Claim rewards later
IGaugeManager(GAUGE_MANAGER).claimRewards(tokenId);

// Or unstake (returns NFT + claims rewards)
IGaugeManager(GAUGE_MANAGER).unstakePosition(tokenId);
```

### 4. Compounding AERO Rewards

```solidity
// Compound rewards directly through GaugeManager
IGaugeManager(GAUGE_MANAGER).compoundRewards(
    tokenId,
    swapData0,     // Swap AERO -> token0
    swapData1,     // Swap AERO -> token1
    minAmount0,    // Minimum token0 expected
    minAmount1,    // Minimum token1 expected
    5000,          // aeroSplitBps: 5000 = 50% to token0, 50% to token1
    deadline       // Transaction deadline
);
```

### 5. Staking Through Vault

```solidity
// For positions already in vault as collateral
IV3Vault(V3_VAULT).stakePosition(vaultTokenId);

// Unstake later
IV3Vault(V3_VAULT).unstakePosition(vaultTokenId);
```

### 6. Advanced Position Management with V3Utils

GaugeManager integrates with V3Utils to enable advanced position management while keeping positions staked. This allows for operations like range changes, liquidity adjustments, and position rebalancing without unstaking.

```solidity
// Example: Shift position by tick spacing with automatic rebalancing
// The executeV3UtilsWithOptionalCompound function handles:
// 1. Unstaking temporarily
// 2. Executing V3Utils operation (range change, swap, etc.)
// 3. Optionally compounding AERO rewards
// 4. Re-staking the position

// See included example script for complete implementation:
// scripts/shift_position_one_tick.py
```

**Key capabilities:**
- **Change position ranges** while maintaining gauge staking
- **Automatic rebalancing** when shifting positions (uses V3 math to calculate exact swap amounts)
- **Integration with 0x** for optimal token swaps during rebalancing
- **Optional AERO compounding** during any V3Utils operation

**Example usage:**
```bash
# Shift position up by tick spacing with automatic rebalancing
python scripts/shift_position_one_tick.py 12345 --up

# Simulate the operation first
python scripts/shift_position_one_tick.py 12345 --up --simulate

# Or use the forge script directly
forge script script/SimpleStakeCompound.s.sol:SimpleStakeCompound \
  --sig "shiftPositionWithSwap(uint256,bool,address,bytes,uint256,uint256)" \
  12345 true 0xTARGET_TOKEN 0xSWAP_DATA SWAP_AMOUNT 5000 \
  --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

## Important Configuration

### Supported Collateral Tokens
- **USDC**: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- **WETH**: `0x4200000000000000000000000000000000000006` 
- **cbBTC**: `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`

### Key Parameters
- **Collateral Factor**: 80% for all supported tokens
- **Liquidation Penalty**: 10%
- **Reserve Factor**: 10%
- **Daily Lend Limit**: 10M USDC
- **Daily Debt Limit**: 10M USDC
- **Max Collateral Value**: 10M USDC per position

### Interest Rate Model
- **Base Rate**: 0% APR
- **Rate at Kink (80%)**: 5% APR
- **Max Rate (100%)**: 100% APR

## Security Considerations

1. **Position Ownership**: Only the owner of a vault position can borrow against it
2. **Liquidation Risk**: Positions can be liquidated if health factor falls below 1.0
3. **Oracle Dependencies**: Price feeds rely on Chainlink oracles
4. **Gauge Rewards**: Staked positions accumulate AERO rewards that must be claimed
5. **Approval Management**: Carefully manage token and NFT approvals

## External Dependencies

- **Aerodrome NPM**: `0x827922686190790b37229fd06084350E74485b72`
- **Aerodrome Factory**: `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A`
- **AERO Token**: `0x940181a94A35A4569E4529A3CDfB74e38FD98631`
- **Universal Router**: `0x6Ff5693b99212DA76ad316178A184aB56d299B43`
- **0x AllowanceHolder**: `0x0000000000001fF3684f28c67538d4D072C22734` (for swaps)
- **Permit2**: `0x000000000022D473030F116dDEE9F6B43aC78BA3`

## Contact & Support

- **Deployer**: `0x3895e33b91f19B279D30B1436640c87E300D2DAc`
- **Block Deployed**: Latest deployment on 2025-08-19
- **Chain**: Base Mainnet (Chain ID: 8453)
- **Note**: Compounding functionality is now integrated directly into GaugeManager

## Example Scripts

The protocol includes example scripts demonstrating advanced integrations:

- **`scripts/shift_position_one_tick.py`** - Complete example showing:
  - Position shifting with automatic rebalancing calculations
  - V3 math implementation for exact swap amounts
  - 0x API integration for optimal swaps
  - Tenderly simulation support
  
- **`script/SimpleStakeCompound.s.sol`** - Forge script examples including:
  - Basic staking and compounding operations
  - Advanced position management with `shiftPositionWithSwap`
  - Range changes with optional AERO compounding

## Next Steps

1. **For Lenders**: Deposit USDC to earn yield
2. **For Borrowers**: Create positions with Aerodrome LP NFTs as collateral
3. **For Liquidators**: Monitor positions for liquidation opportunities
4. **For Integrators**: Use the interfaces above to build on top of the protocol
5. **For Advanced Users**: Explore V3Utils integration for position management while staked

## Verification Status

All contracts except V3Vault have been verified on Basescan. V3Vault verification is pending but the contract is fully functional and operational. Source code is available for review.
