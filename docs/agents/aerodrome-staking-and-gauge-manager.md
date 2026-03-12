# Aerodrome Fork: Staking + GaugeManager

The base whitepaper does not cover this full integration. This file documents the Aerodrome-specific layer.

## 1) Why This Exists

Aerodrome LP positions can be staked in gauges to earn AERO while still being managed through the vault system.

`GaugeManager` is intentionally a vault-controlled adapter, not a second user-facing account system.

## 2) Canonical Custody Paths

Allowed custody paths:

1. Wallet -> Vault (`create`)
2. Vault -> GaugeManager -> Gauge (`stakePosition`)
3. Gauge -> GaugeManager -> Vault (`unstakePosition`)
4. Vault -> Transformer -> Vault (`transform` — auto-unstakes and restakes if position was staked)

Important guardrails:

- Raw user transfer into `GaugeManager` from the NPM is silently accepted but the NFT is NOT tracked in `tokenIdToGauge`. Such NFTs are outside protocol flows and recoverability is not guaranteed. Users must interact through V3Vault only.
- Raw user transfer into vault from a non-NPM contract reverts with `WrongContract()`.

## 3) Vault <-> GaugeManager Responsibilities

Vault:

- User-facing entrypoint for stake/unstake and vault-managed transforms.
- Owner/auth checks for token operations.
- Auto-unstakes on critical paths that require vault custody (`remove`, `liquidate`, `transform`).

GaugeManager:

- `onlyVault` on NFT custody functions (`stakePosition`, `unstakePosition`, `unstakeIfStaked`).
- Reward functions (`claimRewards`, `compoundRewards`) are callable by vault or position owner.
- Maps pool -> gauge and tokenId -> active gauge.
- Performs gauge deposit/withdraw/reward collection.
- Compounds AERO back into position liquidity via swaps.

State synchronization invariants:

- **Loan-token binding:** For every active loan, `V3Vault.loans[tokenId]` must reference a token whose collateral value the vault can access for liquidation. Any operation that replaces a token ID (e.g., token-replacing transforms like AutoRangeAndCompound) must update the vault's loan mapping, or the operation must be blocked for vault positions.
- **Ownership consistency:** `V3Vault.tokenOwner[tokenId]` and `V3Vault.ownedTokens` must stay synchronized with the actual NFT backing the loan. If a token ID changes, the vault's ownership records must be updated atomically.
- **Single source of truth:** The vault is the authoritative record of loan state. Any external path that mutates token identity without going through `V3Vault.transform*` creates desynchronized state — the vault tracks a stale token while the real collateral is unreachable.

## 4) Gauge Configuration Rules

Gauge mapping is explicit owner-configured state:

- `setGauge(pool, gauge)` requires `pool.gauge() == gauge`.
- Unconfigured pools cannot be staked.
- `V3Vault.setGaugeManager(gaugeManager)` is one-shot and irreversible; manager must be deployed for this vault.
- A wrong manager binding is an owner operational misconfiguration and may break gauge flows until redeploy/migration.

Operationally this means new markets require admin gauge mapping before users can stake.

## 5) Reward Claiming And Compounding

Claim:

- `claimRewards(tokenId, recipient)` exists only on `GaugeManager`, not on V3Vault.
- GaugeManager claims from gauge and forwards newly claimed AERO amount to recipient.

Compound:

- Position owner (or vault internal flow) calls `GaugeManager.compoundRewards(...)`.
- Vault-managed transforms can pre-compound staked rewards through `V3Vault.transformWithRewardCompound(...)`, which calls `GaugeManager.compoundRewards(...)` before transform execution.
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

`V3Vault.transform()` handles staked positions transparently:

1. Calls `_unstakeIfNeeded(tokenId)` which returns whether the position was staked.
2. Runs the transform (approve transformer, call transformer, verify custody).
3. If the position was originally staked, automatically restakes the (possibly new) tokenId.

There is no separate `unstakeTransformStake` function. The single `transform()` entrypoint handles both staked and unstaked positions.

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
