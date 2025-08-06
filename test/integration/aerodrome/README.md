# Aerodrome Integration Tests

This directory contains tests for the Aerodrome integration with Revert Lend.

## Test Structure

### Mock Contracts (`mocks/`)
- **MockAerodromePositionManager.sol**: Mock implementation of Aerodrome's position manager
- **MockAerodromeFactory.sol**: Mock implementation of Aerodrome's factory
- **MockGauge.sol**: Mock implementation of Aerodrome gauge for staking

### Test Files
- **AerodromeTestBase.sol**: Base test contract with common setup and helper functions
- **GaugeManager.t.sol**: Unit tests for the GaugeManager contract
- **V3VaultAerodrome.t.sol**: Tests for V3Vault's Aerodrome-specific functionality
- **AerodromeIntegration.t.sol**: End-to-end integration tests

## Running Tests

```bash
# Run all Aerodrome tests
forge test --match-path test/integration/aerodrome/

# Run specific test file
forge test --match-path test/integration/aerodrome/GaugeManager.t.sol

# Run specific test function
forge test --match-test testStakePosition

# Run with gas report
forge test --match-path test/integration/aerodrome/ --gas-report

# Run with verbosity for debugging
forge test --match-path test/integration/aerodrome/ -vvv
```

## Key Test Scenarios

### GaugeManager Tests
- Gauge configuration by admin
- Position staking/unstaking
- Reward claiming and distribution
- Access control and error cases

### V3Vault Integration Tests
- Creating positions with Aerodrome NFTs
- Staking positions through the vault
- Claiming rewards through the vault
- Removing positions with auto-unstaking
- Borrowing against staked positions

### End-to-End Integration Tests
- Full lifecycle: deposit → stake → earn → claim → withdraw
- Multiple users and positions
- Liquidations with staked positions
- Reward accumulation over time

## Important Notes

1. **Position Structure**: Aerodrome positions store `tickSpacing` in the `fee` field (as uint24)
2. **Pool Addressing**: Uses `factory.getPool()` instead of deterministic address computation
3. **Gauge Staking**: Positions must be staked in gauges to earn AERO rewards
4. **Auto-unstaking**: Positions are automatically unstaked when removed from the vault

## Extending Tests

To add new tests:
1. Extend `AerodromeTestBase` for access to common setup
2. Use helper functions like `createPosition()` for consistency
3. Mock any new Aerodrome contracts as needed
4. Follow existing patterns for test organization