# PR46 Human Audit Handoff

## 1) Audit Target
- Repository: `revert-finance/lend`
- Branch: `codex/aerodrome-slipstream-reimpl`
- Commit to audit (exact): `43d46f36ee173f8f671823d8ff8bb8ded9686f72`
- Primary deployment target: **Base** (Aerodrome Slipstream)
- Solidity toolchain: `solc 0.8.24`, Foundry (`via_ir=true`, `optimizer_runs=25`)

## 2) Verification Status (local)
- Build command run:
  - `ANKR_API_KEY=<key> forge build`
- Test command run:
  - `ANKR_API_KEY=<key> forge test`
- Result on target commit:
  - **222 passed, 0 failed**

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
- `src/transformers/AutoRange.sol`
- `src/transformers/AutoCompound.sol`
- `src/transformers/Transformer.sol`

## 4) Trust Model / Privileged Actors
- `V3Vault.owner`:
  - sets collateral configs/limits
  - sets transformer allowlist
  - sets reserve params
  - sets `gaugeManager` (**set once**)
- `V3Vault.emergencyAdmin`:
  - emergency control paths as implemented
- `V3Oracle.owner` and emergency role:
  - token oracle configs, mode, bounds
- `GaugeManager.owner`:
  - `setGauge(pool, gauge)` mapping
- `Automator/Transformer owners`:
  - operator and runtime config controls

## 5) Explicit By-Design Choices (Do Not Auto-Flag Without Context)
1. `transformedTokenId` sentinel is intentionally used as scoped reentrancy guard for transform flows, allowing approved transformer callbacks (including borrow path) for the same token in-transaction.
2. Transform migration does **not** pin to a specific operator contract in `onERC721Received`; flexibility is intentional, with safety relying on transform mode + final custody checks.
3. `setReserveFactor(uint32)` relies on type bound; `Q32 - reserveFactorX32` cannot underflow.
4. `setGaugeManager` is intentionally one-time (immutable after set). Misconfiguration is operationally fatal for staking paths and must be handled by deployment procedure.
5. `FlashloanLiquidator` is intentionally stateless; unsolicited dust/leftover balances are considered out-of-protocol and may be unrecoverable.
6. Direct NFT sends to `GaugeManager` outside vault flow are intentionally untracked/unrecoverable by protocol logic.
7. There is currently no explicit lender “donate/recapitalize” entrypoint in `V3Vault`; bad debt resolution remains via existing reserve/socialization logic.

## 6) Areas Requested for Deep Human Focus
1. Vault transform lifecycle invariants:
   - old/new token debt migration
   - approval cleanup
   - custody post-conditions
2. Gauge liveness under adversarial/reverting gauges:
   - unstake/remove/liquidate should not be bricked by reward claim behavior
3. Flash callback authentication:
   - active context binding
   - factory pool resolution on Slipstream vs Uniswap semantics
4. Oracle safety on mixed pool ABIs:
   - slot0 signed tick decode
   - ticks() tuple compatibility
   - overflow/precision behavior in valuation
5. Governance/ops risk:
   - one-time `setGaugeManager`
   - admin misconfiguration blast radius

## 7) Useful Test Files for Auditor Orientation
- `test/integration/base/BaseAerodromeIntegration.t.sol`
- `test/integration/aerodrome/V3VaultAerodrome.t.sol`
- `test/integration/aerodrome/GaugeManagerVulnerability.t.sol`
- `test/unit/FlashloanLiquidatorCallback.t.sol`
- `test/unit/AutomatorSlot0.t.sol`
- `test/unit/V3OracleSlot0.t.sol`
- `test/atlas/AtlasTransitions.t.sol`
- `test/invariants/AtlasInvariants.t.sol`

## 8) Operational Notes
- Tests that fork Base require `ANKR_API_KEY`.
- No upgrade proxy pattern is used in this branch (non-upgradeable deployment model).
