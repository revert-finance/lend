# Aerodrome Lending Protocol - Integration Guide

## Deployed Contracts on Base Mainnet

| Contract | Address | Basescan |
|----------|---------|----------|
| **V3Vault** | `0xb4694159ef30Fa21bCC9D963C7FA3716b0821E38` | [View](https://basescan.org/address/0xb4694159ef30Fa21bCC9D963C7FA3716b0821E38) |
| **V3Oracle** | `0x896a2FEB2cD936b4083e8d13390Da2DC78935279` | [View](https://basescan.org/address/0x896a2FEB2cD936b4083e8d13390Da2DC78935279) |
| **GaugeManager** | `0x3a9cB8c9b358eD3bC44A539B9Bb356Fe64b08559` | [View](https://basescan.org/address/0x3a9cB8c9b358eD3bC44A539B9Bb356Fe64b08559) |
| **LeverageTransformer** | `0xc138D1f6391C96FBcd3E88a4f9D404007666722e` | [View](https://basescan.org/address/0xc138D1f6391C96FBcd3E88a4f9D404007666722e) |
| **AutoCompound** | `0x06f64F46415aA307c46692f73FD85649086Bd7B9` | [View](https://basescan.org/address/0x06f64F46415aA307c46692f73FD85649086Bd7B9) |
| **InterestRateModel** | `0xd09053a11E07609445806A9581f2678cbf73Af52` | [View](https://basescan.org/address/0xd09053a11E07609445806A9581f2678cbf73Af52) |
| **V3Utils** (existing) | `0x7D1F9FC22beD0798cDA3Fdb18b14a96fc838B9E1` | [View](https://basescan.org/address/0x7D1F9FC22beD0798cDA3Fdb18b14a96fc838B9E1) |
| **Note**: Final deployment on 2025-09-06 with fixed LeverageTransformer constructor and original msg.sender implementation |

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
    
    // Migration Functions
    function migrateToVault(uint256 tokenId, address recipient) external;
    function swapAndIncreaseStakedPosition(
        uint256 tokenId,
        address v3utils,
        V3Utils.SwapAndIncreaseLiquidityParams calldata params
    ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    
    // View Functions
    function tokenIdToGauge(uint256 tokenId) external view returns (address);
    function positionOwners(uint256 tokenId) external view returns (address);
    function poolToGauge(address pool) external view returns (address);
}
```

### 3. LeverageTransformer

Enables leveraging and deleveraging positions using borrowed funds.

```solidity
interface ILeverageTransformer {
    struct LeverageUpParams {
        uint256 tokenId;
        uint256 borrowAmount;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        address recipient;
        uint256 deadline;
    }
    
    struct LeverageDownParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint128 feeAmount0;
        uint128 feeAmount1;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        address recipient;
        uint256 deadline;
    }
    
    // Note: These functions are called through V3Vault.transform()
    function leverageUp(LeverageUpParams calldata params) external;
    function leverageDown(LeverageDownParams calldata params) external;
}
```

## Integration Examples

### 1. Lending USDC (Earn Interest)

```javascript
// Using ethers.js
const vault = new ethers.Contract(VAULT_ADDRESS, V3VaultABI, signer);

// Approve USDC
const usdc = new ethers.Contract(USDC_ADDRESS, ERC20ABI, signer);
await usdc.approve(VAULT_ADDRESS, amount);

// Deposit USDC and receive rlUSDC
const shares = await vault.deposit(amount, userAddress);
```

### 2. Create Position and Borrow

```javascript
// First, approve NFT to vault
const npm = new ethers.Contract(NPM_ADDRESS, NPMABI, signer);
await npm.approve(VAULT_ADDRESS, tokenId);

// Create position in vault
await vault.create(tokenId, userAddress);

// Borrow USDC against position
const borrowAmount = ethers.utils.parseUnits("1000", 6); // 1000 USDC
await vault.borrow(tokenId, borrowAmount);
```

### 3. Stake Position in Gauge

```javascript
// Using GaugeManager to stake and earn AERO rewards
const gaugeManager = new ethers.Contract(GAUGE_MANAGER_ADDRESS, GaugeManagerABI, signer);

// Approve NFT to GaugeManager
await npm.approve(GAUGE_MANAGER_ADDRESS, tokenId);

// Stake position
await gaugeManager.stakePosition(tokenId);

// Later, compound AERO rewards
await gaugeManager.compoundRewards(
    tokenId,
    swapData0,  // 0x swap data for AERO → token0
    swapData1,  // 0x swap data for AERO → token1
    minAmount0,
    minAmount1,
    5000,       // 50% to token0, 50% to token1
    deadline
);
```

### 4. Leverage Position

```javascript
// Using multicall to create position and leverage in one transaction
const leverageParams = {
    tokenId: tokenId,
    borrowAmount: ethers.utils.parseUnits("5000", 6),
    // ... other leverage parameters
};

// Encode function calls
const createData = vault.interface.encodeFunctionData("create", [tokenId, userAddress]);
const transformData = vault.interface.encodeFunctionData("transform", [
    tokenId,
    LEVERAGE_TRANSFORMER_ADDRESS,
    leverageTransformer.interface.encodeFunctionData("leverageUp", [leverageParams])
]);

// Execute multicall
await vault.multicall([createData, transformData]);
```

## Important Notes

1. **Collateral Factors**: Different tokens have different collateral factors:
   - USDC: 90%
   - WETH: 85%
   - cbBTC: 85%
   - AERO: 75%

2. **Interest Rates**: Dynamic based on utilization, managed by InterestRateModel

3. **Liquidation**: Positions can be liquidated when debt exceeds collateral value

4. **AERO Rewards**: Staked positions earn AERO rewards that can be compounded back into the position

5. **Migration**: Positions can be migrated between staking (GaugeManager) and borrowing (V3Vault)

## Security Considerations

1. Always verify contract addresses before interacting
2. Check position health before borrowing
3. Monitor collateral value to avoid liquidation
4. Use appropriate slippage protection in swaps
5. Set reasonable deadlines for time-sensitive operations

## Additional Resources

- [Aerodrome Documentation](https://docs.aerodrome.finance/)
- [Base Documentation](https://docs.base.org/)
- [Contract Source Code](https://github.com/yourusername/aerodrome-lending)