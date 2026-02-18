# Aerodrome Fork: Staking + GaugeManager

The base whitepaper does not cover this full integration. This file documents the Aerodrome-specific layer.

## 1) Why This Exists

Aerodrome LP positions can be staked in gauges to earn AERO while still being managed through the vault system.

`GaugeManager` is intentionally a vault-controlled adapter, not a second user-facing account system.

## 2) Canonical Custody Paths

Allowed custody paths:

1. Wallet -> Vault (`create`, `createWithPermit`)
2. Vault -> GaugeManager -> Gauge (`stakePosition`)
3. Gauge -> GaugeManager -> Vault (`unstakePosition`)
4. Vault -> Transformer -> Vault (unstaked transform)
5. Staked transform wrapper: `unstakeTransformStake` (unstake, transform, restake)

Important guardrails:

- Raw user transfer into `GaugeManager` reverts (`UnexpectedNFT`).
- Raw user transfer into vault for brand-new positions reverts (`UnexpectedDeposit`).

## 3) Vault <-> GaugeManager Responsibilities

Vault:

- User-facing entrypoint for stake/unstake/claim/compound.
- Owner/auth checks for token operations.
- Auto-unstakes on critical paths that require vault custody (`remove`, `liquidate`).

GaugeManager:

- `onlyVault` on NFT-touching functions (`stakePosition`, `unstakePosition`, `claimRewards`, `compoundRewards`).
- Maps pool -> gauge and tokenId -> active gauge.
- Performs gauge deposit/withdraw/reward collection.
- Compounds AERO back into position liquidity via swaps.

## 4) Gauge Configuration Rules

Gauge mapping is explicit owner-configured state:

- `setGauge(pool, gauge)` requires `pool.gauge() == gauge`.
- Unconfigured pools cannot be staked.

Operationally this means new markets require admin gauge mapping before users can stake.

## 5) Reward Claiming And Compounding

Claim:

- Vault position owner calls `vault.claimRewards(tokenId)`.
- GaugeManager claims from gauge and forwards newly claimed AERO amount to recipient.

Compound:

- Vault position owner calls `vault.compoundRewards(...)`.
- GaugeManager:
  1. claims AERO
  2. withdraws staked NFT temporarily
  3. swaps AERO to token0/token1 via router data
  4. increases NFT liquidity
  5. restakes NFT

Swap constraints:

- `aeroSplitBps <= 10000`
- Missing swap data must match split intent:
  - no `swapData0` => split must be 0
  - no `swapData1` => split must be 10000

## 6) Transform Interaction While Staked

Direct transform of staked positions is rejected:

- `V3Vault.transform` reverts with `PositionIsStaked` when token is staked.

Supported staked transform path:

- `V3Vault.unstakeTransformStake(tokenId, transformer, data)`
  - unstake (if staked)
  - run transform in unstaked mode
  - restake resulting tokenId (if originally staked)

This keeps one explicit, auditable path for staked automation.

## 7) Differences From Older Notes

- Current `IGaugeManager` does not include migration helpers like `migrateToVault`.
- Current integration is vault-first; external users should call vault, not gauge manager.

If docs conflict, verify ABI in:

- `src/interfaces/IGaugeManager.sol`
- `src/interfaces/IVault.sol`

## 8) Tests To Trust

- `test/integration/aerodrome/V3VaultAerodrome.t.sol`
- `test/integration/aerodrome/GaugeManagerVulnerability.t.sol`
- `test/integration/aerodrome/GaugeManagerAutoCompound.t.sol`
- `test/atlas/AtlasTransitions.t.sol`
