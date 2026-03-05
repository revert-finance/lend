# PR46 Human Audit Handoff

## 1) Audit Target
- Repository: `revert-finance/lend`
- Branch: `codex/aerodrome-slipstream-reimpl`
- Commit to audit: current branch HEAD (+ any explicitly listed local diff)
- Primary deployment target: **Base** (Aerodrome Slipstream)
- Solidity toolchain: `solc 0.8.24`, Foundry (`via_ir=true`, `optimizer_runs=25`)

## 2) Current Verification Status (local)
- Build:
  - `forge build` passes
- Full tests:
  - `ANKR_API_KEY=<key> forge test --fail-fast`
  - Result: **248 passed, 0 failed, 0 skipped**
- Runtime size:
  - `forge build --sizes`
  - `V3Vault` runtime size: **24,561 bytes** (EIP-170 margin: **+15 bytes**)

## 3) Scope for Human Review (Priority)
### Core custody/accounting
- `src/V3Vault.sol`
- `src/V3Oracle.sol`
- `src/InterestRateModel.sol`

### Staking / gauge integration
- `src/GaugeManager.sol`
- `src/interfaces/IGaugeManager.sol`
- `src/interfaces/aerodrome/*`

### Flash + swap boundary
- `src/utils/FlashloanLiquidator.sol`
- `src/utils/Swapper.sol`

### Automation / transforms
- `src/automators/Automator.sol`
- `src/automators/AutoExit.sol`
- `src/transformers/AutoRangeAndCompound.sol`
- `src/transformers/Transformer.sol`
- `src/transformers/V3Utils.sol`

## 4) Trust Model / Privileged Actors
- `V3Vault.owner`:
  - sets collateral configs/limits
  - sets transformer allowlist
  - sets reserve params
  - sets `gaugeManager` (**set once**)
- `V3Vault.emergencyAdmin`:
  - emergency control paths as implemented
- `V3Oracle.owner` and emergency role:
  - token oracle configs/modes/bounds and sequencer feed
- `GaugeManager.owner`:
  - `setGauge(pool, gauge)` mapping
  - protocol reward fee parameters
- `GaugeManager.withdrawer`:
  - withdraws accumulated protocol fee balances
- `Automator/Transformer owners`:
  - operator/config controls

## 5) Explicit By-Design Choices (Do Not Auto-Flag Without Context)
1. `transformedTokenId` sentinel is intentionally used as scoped reentrancy guard for transform flows, allowing approved transformer callbacks (including borrow path) for the same token in-transaction.
2. Transform migration does **not** pin a specific operator in `onERC721Received`; flexibility is intentional, with safety relying on transform mode + final custody checks.
3. `setReserveFactor(uint32)` relies on type bound; `Q32 - reserveFactorX32` cannot underflow.
4. `setGaugeManager` is intentionally one-time. Misconfiguration is operationally fatal for staking paths and must be controlled by deployment procedure.
5. `FlashloanLiquidator` is intentionally stateless; unsolicited dust/leftover balances are out-of-protocol.
6. Direct NFT sends to `GaugeManager` outside vault flow are intentionally rejected/untracked for protocol accounting.
7. No explicit lender donation/recapitalization entrypoint is exposed in `V3Vault`.

## 6) Areas Requested for Deep Human Focus
1. Vault transform lifecycle invariants:
   - old/new token debt migration
   - approval cleanup
   - custody post-conditions
2. Gauge liveness under adversarial/reverting gauges:
   - unstake/remove/liquidate behavior if `getReward` reverts
3. Flash callback authentication:
   - active context binding
   - pool authenticity checks across Slipstream/Uniswap layouts
4. Oracle safety on mixed pool ABIs:
   - slot0 signed tick decode
   - ticks() tuple compatibility
   - overflow/precision behavior in valuation paths
5. Governance/ops risk:
   - one-time `setGaugeManager`
   - admin misconfiguration blast radius
6. Daily debt cap logic around haircut/socialization paths.

## 7) Useful Test Files for Auditor Orientation
- `test/integration/base/BaseAerodromeIntegration.t.sol`
- `test/integration/aerodrome/V3VaultAerodrome.t.sol`
- `test/integration/aerodrome/GaugeManagerVulnerability.t.sol`
- `test/integration/aerodrome/FlashloanLiquidator.t.sol`
- `test/unit/FlashloanLiquidatorCallback.t.sol`
- `test/unit/AutomatorSlot0.t.sol`
- `test/unit/V3OracleSlot0.t.sol`
- `test/atlas/AtlasTransitions.t.sol`
- `test/invariants/AtlasInvariants.t.sol`

## 8) Operational Notes
- Base-fork tests require `ANKR_API_KEY` / `ANKR_KEY`.
- Non-upgradeable deployment model (no proxy/diamond).
- Foundry lint notes remain mostly style/import naming noise and do not block build/tests.
- `V3Vault` is close to EIP-170 limit (current margin ~19 bytes at `optimizer_runs=25`, `via_ir=true`); any added logic/events can push it over.
