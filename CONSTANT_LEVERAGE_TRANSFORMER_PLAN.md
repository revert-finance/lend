# ConstantLeverageTransformer Implementation Plan

## Executive Summary

This document outlines the implementation plan for a `ConstantLeverageTransformer` contract for V3Lend that maintains a target leverage ratio automatically. The contract will support both Uniswap V3 and Aerodrome Slipstream deployments.

## Background

### V4Lend AUTO_LEVERAGE Reference

The v4lend codebase (`/Users/kalinbas/Code/v4lend`) implements AUTO_LEVERAGE as part of the RevertHook system:

- **Trigger System**: Uses hook callbacks (`afterSwap`) to detect price movements
- **Tick-Based Triggers**: Rebalances at `baseTick ± 10 * tickSpacing`
- **Target Ratio**: Stored as `autoLeverageTargetBps` (0-9999 bps)
- **Key Functions**: `_increaseLeverage()` and `_decreaseLeverage()` in `RevertHookFunctions2.sol`

### V3Lend Architecture (This Codebase)

- **No Hook System**: V3Lend uses external transformers and automators
- **Transformer Pattern**: Contracts execute via `vault.transform(tokenId, transformer, data)`
- **Automator Pattern**: Bot-controlled contracts with operators, TWAP protection, and rewards
- **Existing Reference**: `LeverageTransformer.sol` provides manual `leverageUp()` and `leverageDown()`

## Design Decisions

### 1. Contract Architecture

The `ConstantLeverageTransformer` will combine patterns from:
- `Transformer` - for vault integration and caller validation
- `Automator` - for operator management, TWAP protection, and bot execution
- `LeverageTransformer` - for leverage mechanics and swap handling

```
ConstantLeverageTransformer
├── extends Transformer (vault whitelist, caller validation)
├── extends Automator (operators, TWAP, swapping)
└── uses LeverageTransformer patterns (borrow/repay/swap logic)
```

### 2. Position Configuration

```solidity
struct LeverageConfig {
    // Target debt-to-collateral ratio in basis points (e.g., 5000 = 50% = 2x leverage)
    uint16 targetLeverageBps;

    // Threshold below target to trigger leverage increase (e.g., 1000 = 10%)
    uint16 lowerThresholdBps;

    // Threshold above target to trigger leverage decrease (e.g., 1500 = 15%)
    uint16 upperThresholdBps;

    // Max slippage for swaps in basis points (e.g., 100 = 1%)
    uint16 maxSlippageBps;

    // Optional: specific swap path or pool for better execution
    bytes swapPath;
}
```

**Leverage Calculation**:
- `leverageRatio = collateralValue / (collateralValue - debt)`
- For 2x leverage: `debt = 50%` of collateral value (targetBps = 5000)
- For 3x leverage: `debt = 66.67%` of collateral value (targetBps = 6667)

### 3. Trigger Mechanism

Since V3Lend lacks hooks, we need an external trigger system:

**Option A: Permissionless with Incentive (Recommended)**
- Anyone can call `rebalance()` if position is outside threshold
- Caller receives a small reward (configurable, e.g., 0.1% of rebalanced value)
- Reward comes from position's fees or a small increase in debt

**Option B: Operator-Only**
- Only whitelisted operators can execute
- Simpler but centralized
- Pattern matches existing AutoCompound/AutoRange

**Recommendation**: Start with Option B (operator-only) for initial release, add permissionless incentives in v2.

### 4. Rebalancing Logic

```
checkRebalanceNeeded(tokenId):
    1. Get current loan info: (debt, fullValue, collateralValue, ...)
    2. Calculate currentRatioBps = debt * 10000 / collateralValue
    3. Get config for position
    4. If currentRatioBps < targetBps - lowerThresholdBps:
        → Need to INCREASE leverage (borrow more)
    5. If currentRatioBps > targetBps + upperThresholdBps:
        → Need to DECREASE leverage (repay debt)
    6. Otherwise: No rebalance needed

rebalance(tokenId, swapData):
    1. Validate caller is operator
    2. Check TWAP is within bounds
    3. Call vault.transform() with rebalance data
    4. Inside transform:
        - If increasing: borrow → swap → increaseLiquidity
        - If decreasing: decreaseLiquidity → swap → repay
    5. Emit event with before/after states
```

### 5. Safety Mechanisms

1. **TWAP Protection**: Reuse Automator's `_hasMaxTWAPTickDifference()` to prevent sandwich attacks
2. **Slippage Protection**: Per-position `maxSlippageBps` configuration
3. **Cooldown Period**: Optional minimum time between rebalances
4. **Max Leverage Limit**: Global cap on `targetLeverageBps` (e.g., 9000 = 10x max)
5. **Health Check**: Ensure position remains healthy after rebalance

## Implementation Tasks

### Phase 1: Core Contract Development

#### 1.1 Create ConstantLeverageTransformer Contract

**File**: `src/transformers/ConstantLeverageTransformer.sol`

```solidity
// Key components:
- Position configuration storage
- Rebalance check logic
- Leverage increase/decrease implementation
- Swap integration (pool swap or router swap)
- Event emissions
```

#### 1.2 Create Interface

**File**: `src/interfaces/IConstantLeverageTransformer.sol`

```solidity
interface IConstantLeverageTransformer {
    struct LeverageConfig {
        uint16 targetLeverageBps;
        uint16 lowerThresholdBps;
        uint16 upperThresholdBps;
        uint16 maxSlippageBps;
    }

    function setPositionConfig(uint256 tokenId, LeverageConfig calldata config) external;
    function getPositionConfig(uint256 tokenId) external view returns (LeverageConfig memory);
    function checkRebalanceNeeded(uint256 tokenId) external view returns (bool needed, bool isIncrease);
    function rebalance(uint256 tokenId, bytes calldata swapData) external;
    function rebalanceWithVault(uint256 tokenId, address vault, bytes calldata swapData) external;
}
```

### Phase 2: Integration Points

#### 2.1 Vault Integration
- Register transformer with V3Vault via `setVault()`
- Users approve transformer via `vault.approveTransform(tokenId, transformer, true)`

#### 2.2 Swap Integration
- Support both pool swaps (for simple pairs) and router swaps (for complex paths)
- Reuse `Swapper.sol` utilities

### Phase 3: Aerodrome Version

#### 3.1 Create Aerodrome Variant
- Inherit from base ConstantLeverageTransformer
- Handle Aerodrome-specific position manager interface differences
- Consider gauge rewards integration (stake/unstake during rebalance)

**Files**:
- `src/transformers/ConstantLeverageTransformerAerodrome.sol`
- Use patterns from `origin/aero-lend-squash` branch

### Phase 4: Testing

#### 4.1 Unit Tests

**File**: `test/integration/transformers/ConstantLeverageTransformer.t.sol`

Test scenarios:
1. Configuration setting/getting
2. Rebalance detection (above threshold, below threshold, within band)
3. Leverage increase flow
4. Leverage decrease flow
5. TWAP protection triggering
6. Slippage protection
7. Unauthorized caller rejection
8. Edge cases (near liquidation, dust amounts)

#### 4.2 Integration Tests

- Full flow with actual vault borrowing
- Multiple consecutive rebalances
- Interaction with other transformers

### Phase 5: Bot Implementation

#### 5.1 Off-Chain Bot

**Location**: Separate repository or `bot/` directory

Components:
1. **Position Monitor**: Poll vault positions for configured addresses
2. **Threshold Checker**: Calculate if rebalance needed
3. **Swap Quote Fetcher**: Get optimal swap data from 0x API
4. **Transaction Builder**: Construct and submit rebalance tx
5. **Gas Optimization**: Batch multiple positions if efficient

### Phase 6: Deployment & Documentation

#### 6.1 Deployment Scripts
- `script/DeployConstantLeverageTransformer.s.sol`
- Configure for each network (mainnet, Base, Arbitrum)

#### 6.2 Documentation
- User guide for setting up constant leverage
- API documentation
- Risk disclosures

## Contract Structure

```
src/
├── transformers/
│   ├── ConstantLeverageTransformer.sol          # Main contract (Uniswap)
│   └── ConstantLeverageTransformerAerodrome.sol # Aerodrome variant
├── interfaces/
│   └── IConstantLeverageTransformer.sol
test/
├── integration/
│   └── transformers/
│       ├── ConstantLeverageTransformer.t.sol
│       └── ConstantLeverageTransformerAerodrome.t.sol
script/
└── DeployConstantLeverageTransformer.s.sol
```

## Key Differences from V4Lend AUTO_LEVERAGE

| Aspect | V4Lend AUTO_LEVERAGE | V3Lend ConstantLeverageTransformer |
|--------|---------------------|-----------------------------------|
| Trigger | Hook-based (afterSwap) | Bot-initiated (operator call) |
| Threshold | Fixed ±10 tick spacing | Configurable bps thresholds |
| Config Storage | In RevertHook state | In transformer contract |
| Execution | Automatic on swap | Manual call by operator |
| Swap | Pool-specific calculation | External swap data (0x/router) |

## Risk Considerations

1. **Liquidation Risk**: Aggressive leverage targets near max LTV could liquidate on rebalance
2. **Gas Costs**: Each rebalance costs gas; small positions may not be economical
3. **Swap Slippage**: Large rebalances in illiquid pools may suffer slippage
4. **Oracle Manipulation**: TWAP protection mitigates but doesn't eliminate risk
5. **Bot Reliability**: Positions depend on bot uptime for timely rebalancing

## Open Questions

1. **Reward Mechanism**: Should we implement caller rewards for permissionless execution?
2. **Gas Subsidies**: Should protocol subsidize rebalance gas for small positions?
3. **Compound Integration**: Should rebalances also compound fees automatically?
4. **Emergency Exit**: Should there be a mechanism to disable leverage and exit to safe state?

## Next Steps

1. Review and approve this plan
2. Implement Phase 1 (core contract)
3. Write comprehensive tests
4. Internal code review
5. Deploy to testnet
6. Security audit
7. Mainnet deployment
