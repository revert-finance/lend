# Implementation plan: Coinbase B20 equity-collateral vault on Base

**Purpose:** everything that must be written, configured and verified to *prepare* this deployment.
**Nothing in this plan broadcasts a transaction to Base.** Deployment itself is a separate,
gated step at the end (§5) and happens only after the go/no-go list (§6) is fully green.
**Audience:** an implementing agent starting cold. Read `docs/proposal-coinbase-equity-collateral-base.md`
(the "proposal") first — it holds the analysis and every on-chain address; this document holds the work.
**Also read:** `docs/agents/README.md`, `docs/agents/risk-and-acceptability.md` (fail-closed oracle
policy is *intentional* — do not "fix" it), `docs/agents/protocol-primer.md`.

---

## 0. Scope

**In scope (pilot):** new `V3Oracle`, `InterestRateModel`, `V3Vault`, `FlashloanLiquidator`
(MinUnstake-bound, no owner), seven `ChainlinkMultiplierFeed` adapters (ownerless, immutable),
reuse of V3Utils `0xc3cFFd…Fe2dD`,
deploy/verify/freeze scripts, mock + live-simulation tests, runbook, manifest, go/no-go.

**Out of scope (pilot):** GaugeManager/staking (one-shot `setGaugeManager`; MinUnstake gauge reward
flow unsimulated; see `docs/investigation-aerodrome-stuck-unstake-71869354.md`), LeverageTransformer,
AutoRangeAndCompound, AutoExit, frontend, MSTRc, SPCXc. Each may be added later by its own plan.

---

## 1. Branch, toolchain, conventions

### 1.1 Branch

Start from **`aerodrome-slipstream`** — https://github.com/revert-finance/lend/tree/aerodrome-slipstream.
It is the Aerodrome fork (`Swapper` resolves pools via `factory.getPool(a, b, tickSpacing)`,
Aerodrome mint selector, `IAerodromeNonfungiblePositionManager`); `main` is Uniswap-only and will
not work.

```sh
git checkout aerodrome-slipstream            # LOCAL branch — see dependency note below
git checkout -b codex/coinbase-b20-equity-vault
```

**All work in this plan — contracts, tests, scripts, these docs — is committed on
`codex/coinbase-b20-equity-vault`, never directly on `aerodrome-slipstream`** (decided by Mario,
2026-09-16). It is merged back by PR when the DoD (§5) is met.

**Dependency:** branch off the *local* `aerodrome-slipstream`, not `origin/aerodrome-slipstream`.
Three commits exist locally but are **not on origin** as of 2026-09-16 (`d4ebac0` design spec,
`1238ba5` `DeployBaseV3UtilsMinUnstakeFactory.s.sol` + keystore change, `52dd557`
`script/DEPLOY_AERODROME_V3UTILS.md`, plus the fixup that corrects its ownership section). This plan
depends on that V3Utils record. Get them onto origin (PR from `codex/aerodrome-v3utils-new-factories`
into `aerodrome-slipstream`) before this branch's PR. Do not lose them.

### 1.2 Toolchain and signing

- Foundry; `foundry.toml` pins `solc 0.8.24`, `via_ir = true`, `optimizer_runs = 25`. No
  `[rpc_endpoints]` exist — pass `--rpc-url` explicitly. `$BASE_RPC_URL` is **not** set in the shell;
  forge silently falls back to `localhost:8545` and fails with "Connection refused". Export it.
- Scripts sign with the forge keystore: `--account deployer`. **That account resolves to
  `0x83681C14770b44361e21Faf91D8325423365eA5C`, the high-frequency auto-compound bot** (nonce
  >1.1M on Base). Acceptable as a *broadcaster*; **every deployed contract must end owned by the
  multisig**, and the deploy script must assert that before exiting. Its nonce moves every few
  minutes — a collision fails harmlessly; retry.
- **Ownership pattern — DECIDED (Mario, 2026-09-16): option A, all contracts owned directly by the
  2-of-3 Safe, exactly like rlAeroUSDC.** Verified facts behind the choice:
  `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9` is a **2-of-3 GnosisSafeProxy v1.3.0**, not a timelock. The live **rlAeroUSDC** deployment is
  uniformly Safe-owned (vault `0x1ef7c181…`, oracle `0x82722327…`, IRM `0x9E29b743…`, GaugeManager
  `0xc171F8c6…` all `owner() == Safe`). **rlAeroUSDC is the outlier: every other live vault is
  timelock-owned.** rlBaseUSDC → `TimelockController` `0x36bF9981bA905cA63Bdd3271775DB43CC57eB1CF`
  (48h); Arbitrum → `0x199B7d994c9d3A26ff81E93bdB5dBc780363F330` (48h); mainnet →
  `0xff2Dc15Bb5ffd7d2a1E9Dc6bb63B6C78A3d72145` (48h). On each, the chain's Safe holds PROPOSER +
  EXECUTOR + CANCELLER and nobody holds DEFAULT_ADMIN (role set frozen). In all four deployments the
  **oracle is owned directly by the Safe**. Summary:

  | deployment | vault owner | oracle owner |
  | --- | --- | --- |
  | Base rlAeroUSDC | Safe 2-of-3 | Safe |
  | Base rlBaseUSDC | Timelock 48h | Safe |
  | Arbitrum | Timelock 48h | Safe |
  | Mainnet | Timelock 48h | Safe |

  The choice interacts with `emergencyAdmin = none`: a timelock-owned vault makes `setLimits`
  48h-gated, so the Friday freeze must be scheduled by Wednesday 15:00 ET and no emergency response
  can land in under 48h — which is why A was chosen for the pilot. Revisit option C (timelock owner
  + Safe as `emergencyAdmin`) before raising caps beyond pilot. Scripts hardcode
  `OWNER = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9` and assert `owner() == OWNER` on every
  contract post-deploy.
- **Ownership mechanics — read before writing any script.** Verified in source (2026-09-16):
  `V3Vault`, `V3Oracle`, `Transformer` (→ `V3Utils`), `GaugeManager`, `Automator` are
  **`Ownable2Step`**: `transferOwnership(x)` only sets `pendingOwner`; the new owner must call
  `acceptOwnership()` from its own account, and until then the *deployer remains owner*.
  `InterestRateModel` is plain `Ownable` (transfer is immediate). **`FlashloanLiquidator` has no
  ownership at all** (`Swapper, IUniswapV3FlashCallback` only) — there is nothing to transfer, and a
  script calling `transferOwnership` on it will not compile. `ChainlinkMultiplierFeed` has **no
  owner either** (immutable, nothing to administer — decided 2026-09-16). Consequences: every deploy script asserts `pendingOwner() ==
  MULTISIG` (not `owner()`) on 2-step contracts at exit and prints the Safe `acceptOwnership()` batch;
  the manifest and the verify script assert `owner() == MULTISIG && pendingOwner() == address(0)`;
  no configuration step that requires the Safe as owner (`V3Utils.setVault`, final `setLimits`) is
  possible until the Safe has accepted. Precedent: `DeployAerodromeProtocol.s.sol` only calls
  `transferOwnership`; the Safe accepted in separate transactions.
- **`emergencyAdmin`: not set (`address(0)`) — matches the live Aerodrome deployment** (decided by
  Mario 2026-09-16). Verified on-chain across the **whole house**: every live vault and every live
  oracle — Base rlAeroUSDC, Base rlBaseUSDC, Arbitrum, mainnet — returns `emergencyAdmin() ==
  address(0)`, and **zero `SetEmergencyAdmin` events have ever been emitted** on any of the four
  vaults; `DeployAerodromeProtocol.s.sol` never calls `setEmergencyAdmin`. The role has never been
  used anywhere.
  The role gates exactly two functions — `V3Vault.setLimits` (`V3Vault.sol:875`) and
  `V3Oracle.setOracleMode` (`V3Oracle.sol:293`) — so with it unset both are **multisig-only**.
  Every Friday freeze and Sunday unfreeze is therefore a multisig transaction (WP6).
- **B20 tokens cannot execute on anvil/revm forks** (native client code, `0xef`). Do not build
  fork-based tests that call `transfer`/`multiplier` on the real tokens; they will revert. See WP3.

### 1.3 House conventions to match

- Scripts: hardcoded checksummed `constant` addresses; `_validateDeploymentConfig()` with
  `_requireCode` / linkage `require`s before `vm.startBroadcast()`; bare `vm.startBroadcast()` (signer
  from CLI, no `PRIVATE_KEY`); `console2.log` every deployed address. Model on
  `script/DeployAerodromeProtocol.s.sol` and `script/DeployBaseV3UtilsMinUnstakeFactory.s.sol`.
- Tests: mock-based under `test/integration/aerodrome/` using `AerodromeTestBase.sol` and
  `mocks/` (`MockPool` has `slot0`/`observe`/`swap`/`setSqrtPriceX96`/`setObservedTick`;
  `MockAerodromePositionManager` has `positions`/`setPosition`/`mint`; `MockERC20` takes decimals).
  Unit tests under `test/unit/`.
- Commit messages end with the attribution line required by the session (currently
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
- Document hierarchy: `src/` > `test/` > `docs/agents/` > everything else.

---

## 2. Work packages

Ordered by dependency. WP0 and WP1 can start immediately and in parallel; WP2–WP7 depend as noted.

### WP0 — Time-sensitive on-chain actions (no new protocol code)

These accrue value forward-only or unblock everything else. Do them first.

**WP0.1 `script/IncreaseB20PoolCardinality.s.sol`** — permissionless, **optional defence-in-depth,
not a blocker** (reclassified 2026-09-16 after review). Why it is not a blocker: `observe([60, 0])`
needs one stored observation ≥ 60 s old. A ring of 360 slots is only exhausted by 360 *consecutive
touched blocks*, and only 30 blocks fit in 60 s at 2 s/block — so a 60 s TWAP cannot fail on a 360
ring; on a quiet pool the ring spans longer, never shorter. The original "~12 min worst case" is
still 12× the window. The bump only buys margin for a future longer `twapSeconds`.
- If done: target **2048** (match the four pools that already have it), not 4320. Each new slot is a
  fresh storage write (~20k gas): 360→2048 ≈ 34M gas per pool; 360→4320 ≈ 80M and may need
  chunking. Cheap in dollars on Base, but not free of operational friction.
- Constants: the three 360-ring pools (MSFTc, AMZNc, TSLAc — proposal §2.3), MinUnstake factory.
- Preflight: `block.chainid == 8453`; code; `pool.factory() == MinUnstake factory`;
  `pool.tickSpacing() == 10`; skip pools with `observationCardinalityNext ≥ target`.
- Action: `increaseObservationCardinalityNext(target)`; post: read `slot0()`, log.
- Acceptance: dry-run passes. **The deployment gate is not a cardinality number** — it is
  "`pool.observe([twapSeconds, 0])` succeeds at the deploy block and measured ring coverage ≥ 10×
  `twapSeconds`" (WP3 bucket 2 `ring_coverage.sh`). Record any bump in `script/DEPLOY_COINBASE_EQUITY.md`.

**WP0.2 V3Utils ownership** — `0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD` is owned by the hot key.
`V3Utils` is **`Ownable2Step`** (via `Transformer`) — two transactions from two accounts:
```sh
# 1. current owner (hot key) proposes
cast send 0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD "transferOwnership(address)" <MULTISIG> \
  --rpc-url "$BASE_RPC_URL" --account deployer
cast call 0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD "pendingOwner()(address)" --rpc-url "$BASE_RPC_URL"
# 2. the Safe accepts (Safe tx: to = V3Utils, data = acceptOwnership(), selector 0x79ba5097)
cast calldata "acceptOwnership()"
cast call 0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD "owner()(address)" --rpc-url "$BASE_RPC_URL"
```
Acceptance: `owner() == MULTISIG && pendingOwner() == address(0)` on-chain. Until step 2 lands the
hot key is still the owner. Blocking before any `setVault`/`setTransformer`.
Same for the Gauge-Caps V3Utils `0x93a8F1FFAae10e3E5B67a0F36aB9581bCDc463C7` (not used here, same
open item). Current state (2026-09-16): `pendingOwner() == 0x0` on both — nothing proposed yet.

### WP1 — External confirmations (non-code; owner: Mario / legal) — **blocking**

Record each outcome, with the source document, in `docs/proposal-coinbase-equity-collateral-base.md §7`.

1. **Chainlink**: are `Coinbase TICKER` feeds **share-basis** (adjusted at corporate actions) or
   token-basis? Written answer. This decides whether WP2 multiplies or not.
2. **Coinbase**: does `multiplier` ever scale `balanceOf`/`transfer`, or is it redemption-layer only?
   Change-control process for `updateMultiplier`, pause, blocklist (policy ID 5), burn/seizure.
   Treatment of protocol/pool addresses. Which multiplier interfaces are live (`multiplier()` yes;
   `uiMultiplier`/`newUIMultiplier`/`effectiveAt` revert today).
3. **Issuer role/policy enumeration.** Policy state **is pollable** (corrected 2026-09-16; the
   earlier probe called `isAuthorized` on the *token*, which is the wrong surface): each token exposes
   `policyId(bytes32 scope) → uint64`, and the **PolicyRegistry precompile
   `0x8453000000000000000000000000000000000002`** exposes `isAuthorized(uint64,address)`,
   `policyExists(uint64)`, `policyAdmin(uint64)`, `pendingPolicyAdmin(uint64)`. Verified live:
   `TRANSFER_SENDER/RECEIVER/EXECUTOR_POLICY` and `MINT_RECEIVER_POLICY` all resolve to **policy 5**
   on NVDAc and MSFTc (SEIZE scopes unset/revert); `policyExists(5) == true`; `isAuthorized(5, x)`
   is `true` for the pools and a fresh EOA and also `true` for a nonexistent id → **blocklist
   semantics confirmed**. **`policyAdmin(5) == 0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812` — a plain
   EOA (no code), unverified.** Deliverables: confirm the same on all seven tokens; enumerate
   *role holders* (MINT/BURN/SEIZE/PAUSE/UNPAUSE/METADATA/OPERATOR) from `RoleGranted` logs, which
   are not otherwise enumerable; ask Coinbase who controls the policy-admin EOA and under what
   process. Attach `script/sim/policy_registry.sh` and `roles_from_logs.py`.
4. **Legal**: permissionless lending/liquidation of tokenized securities — lenders, borrowers,
   liquidators, governance, frontend, automation operators; eligible-holder and geographic
   restrictions; state what protection/notice/redemption rights exist.
5. **Historical gap reproduction**: adjusted close → next-session-open for the seven names from a
   documented source, incl. holidays and exceptional closures (review found max −10…19%).

If (1) is token-basis → **WP2 is not needed at all**: wire the raw Chainlink feeds directly, as
every live vault does. If (2) says balances can scale → **stop; this collateral type is
undeployable** on v3 pool accounting.

### WP2 — Contract: `src/utils/ChainlinkMultiplierFeed.sol` (+ `src/interfaces/IB20Multiplier.sol`)

**Status (2026-09-16): implemented on `codex/coinbase-b20-equity-vault`** — commit `4ecf020`;
modeled on the house `ChainlinkFeedCombinator` (ownerless, immutable, invalid input → `answer = 0`
so `V3Oracle` rejects the round); `test/unit/ChainlinkMultiplierFeed.t.sol` 19 tests green.
Independent review of the diff still required (DoD §5).

Depends on WP1.1/WP1.2 for the final multiply-or-not decision; **build it now**. One contract,
seven instances (one per equity). **The adapter does exactly one thing: multiply the Chainlink share
price by the token's `multiplier()`, failing closed if that call reverts or returns zero.**

**No answer bounds, no owner (decided by Mario 2026-09-16).** An earlier revision added C4 #446
min/max bounds to the adapter and a bounds-only instance for the USDC reference feed. Both were
dropped as redundant with `CHAINLINK_TWAP_VERIFY`: the Chainlink-derived price is
`equityUSD / usdcUSD` and the TWAP is `equity/USDC` straight from the pool, so a garbage print on
**either** feed — an equity feed *or* the USDC reference — diverges by more than 3% from the TWAP and
`_requireMaxDifference` reverts, for all seven names in the USDC case. That is a dynamic ±3% bound;
a static band behind it catches nothing extra. USDC is therefore wired to the raw Chainlink feed in
forced `Mode.CHAINLINK`, exactly like every live vault. C4 #446 remains unfixed house-wide and this
vault is no different; it is recorded as accepted-and-covered in the proposal.

`V3Oracle` calls only `feed.decimals()` (`V3Oracle.sol:256`, at `setTokenConfig`) and
`feed.latestRoundData()` (`:419`). The adapter is therefore a minimal `AggregatorV3Interface`.

```solidity
interface IB20Multiplier { function multiplier() external view returns (uint256); } // 1e18 = 1.0

contract ChainlinkMultiplierFeed is AggregatorV3Interface {      // no owner, nothing to administer
    AggregatorV3Interface public immutable feed;   // Chainlink "Coinbase TICKER"
    IB20Multiplier      public immutable token;    // the B20 token
    error InvalidAnswer(); error InvalidMultiplier();

    function decimals() external view returns (uint8) { return feed.decimals(); }
    function description() ...; function version() ...;
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 ar) = feed.latestRoundData();
        if (a <= 0) revert InvalidAnswer();
        uint256 m = token.multiplier(); if (m == 0) revert InvalidMultiplier();  // revert → fail-closed
        return (r, int256(uint256(a) * m / 1e18), s, u, ar);              // floor; see rounding note
    }
    function getRoundData(uint80) ... // same transform, or revert NotSupported — V3Oracle never calls it
}
```

Requirements:
- `token.multiplier()` reverting → adapter reverts → fail-closed. `m == 0` → revert.
- Overflow: `a` ≤ ~1e11 (8-dec, ≤ $1,000/share) × `m` ≤ ~1e19 → < 1e30, fits `uint256`; keep an
  explicit sanity `require(m <= 1e21)` or document the bound. Rounding: floor; error is ≤ 1 unit of
  feed precision (1e-8 $), negligible against `maxDifference` 3% — state this in a comment.
- `feed` and `token` immutable; no owner, no setters, no pause. Nothing that could make it fail
  *open*. Replacing an adapter = deploying a new one and `setTokenConfig` from the Safe.
- Acceptance: WP3 bucket-1 tests green for every row of proposal §3.2's matrix; **independent
  review of the exact diff** recorded in the PR.

### WP3 — Tests (three buckets; record the split so nothing is silently waived)

**Bucket 1 — mock-tested, local (`forge test`).** **Status: implemented** (commit `b29f155`):
`test/integration/aerodrome/B20TestBase.sol`, `mocks/MockB20Token.sol`, `mocks/MockChainlinkFeed.sol`,
`V3OracleB20.t.sol` (28), `V3VaultB20.t.sol` (11 + 1) — 40 tests green. `MockPool.observe` was
corrected to the Uniswap cumulative sign convention (previous tests only used tick 0).
Add `test/integration/aerodrome/mocks/MockB20Token.sol`: `MockERC20` with 8 decimals plus
`multiplier()` (settable), `setRevertMultiplier(bool)`, and `setBlocked(address, bool)` making
`transfer`/`transferFrom` revert for blocked `from`/`to`/`msg.sender` (simulates policy gating).
Reuse `MockPool`, `MockAerodromePositionManager`, and the existing mock Chainlink feed in
`AerodromeTestBase.sol` (extract to `mocks/MockChainlinkFeed.sol` if not already separate).

- `test/unit/ChainlinkMultiplierFeed.t.sol` — every row of the §3.2 matrix: dividend Δ≈0.04%
  tracks; 2:1 and 1:2 splits with feed print before/after multiplier flip; emergency cut;
  fat-finger inside/outside 3%; `multiplier()` revert; `m == 0`; `a <= 0`; decimals passthrough;
  `getRoundData` behaviour; no state-changing function exists.
- `test/integration/aerodrome/V3OracleB20.t.sol` — `V3Oracle(mockNpm, USDC6, address(0))`;
  USDC in forced `Mode.CHAINLINK` on the raw mock feed; an 8-decimal token in
  `CHAINLINK_TWAP_VERIFY` via the adapter. **Garbage-print coverage (replaces bounds):** an absurd
  equity feed print (10× / 0.1×) → `getValue` reverts on that token via divergence; an absurd USDC
  reference print (10× / 0.1×) → `getValue` reverts on **every** equity via divergence; a USDC move
  to $0.98 (inside 3%) reprices all equities correctly.
  Cover: the `referenceTokenDecimals < tokenDecimals` scaling branch (`V3Oracle.sol:355-363`) with
  8-dec token vs 6-dec reference against a known price; staleness revert at `maxFeedAge`; divergence
  revert at `maxDifference`; spot-vs-derived revert at `maxPoolPriceDifference`; blackout table
  (proposal §3.3) — `create`/deposit succeeds, `borrow` reverts, `liquidate` reverts, `repay`
  succeeds, lender `withdraw` succeeds; multiplier transition with pool repriced *before* vs *after*
  the feed print, including auto-recovery at the first adjusted print; reopen-wick scenario.
- `test/integration/aerodrome/V3VaultB20Limits.t.sol` — `collateralValueLimitFactorX32` binds on
  **both** legs; caps scale with `lentAssets`; sum-of-caps vs `globalDebtLimit` ordering; the
  **freeze tuple** `setLimits(minLoan, lendLimit, currentDebt, 0, 0)` blocks new borrows and does
  **not** block `repay` or `liquidate` (verify `_calculateDailyIncreaseLimit` semantics with mins 0);
  `minLoanSize` enforcement; **equity/equity cross pairs**: a mock pool of two configured
  equities is accepted as collateral via `create` with no allowlist; `min(CF0, CF1)` applies; both
  caps bind; both legs revert valuation in the same blackout (no USDC leg).

**Bucket 2 — live-simulated (stateless `eth_call` against a live Base node, pinned block; no
broadcast).** Under `script/sim/` (bash + python or forge scripts run without `--broadcast`), each
writing JSON to `script/sim/out/`. **Scope limit (2026-09-16): a sequence of `eth_call`s shares no
state, so borrow → repay → liquidate cannot be chained here; that flow moves to the Stage-B on-chain
smoke test (WP4/§4).** Spike first: check whether Tenderly `simulate-bundle` or Alchemy
`simulateExecutionBundle` executes B20 calls (they run their own EVMs and very likely hit the same
`0xef` wall as anvil); if one does, chained flows may run there — record the result either way.
- `canary.sh` — simulated `transfer` with `from` overrides: pool → fresh EOA; pool → vault (once
  known); NPM → FlashloanLiquidator; fresh EOA → pool. All must return `true`.
- `policy_registry.sh` — for each token, `policyId(scope)` for all six scopes; for each resolved id,
  registry `policyExists`, `policyAdmin`, `pendingPolicyAdmin`, and `isAuthorized(id, x)` for x ∈
  {vault, oracle, NPM, V3Utils, FlashloanLiquidator, each pool, named liquidators}. All `true`;
  admin recorded. This is also the WP6 poller.
- `tickwalk_exit.py` — WP5's model (below).
- `feed_roundwalk.sh` — walk each aggregator's rounds back ≥ 2 weekends; assert the gap and the
  weekday maxima; sample feed-vs-pool divergence across an **overnight** session (needed to freeze
  `maxDifference`).
- `ring_coverage.sh` — `pool.observe([60, 0])` succeeds on all seven at the pinned block; measured
  ring span (oldest initialized observation age) ≥ 10× `twapSeconds`; report cardinality for
  information only.
- `zerox_quotes.sh` — live 0x AllowanceHolder quote for each B20↔USDC pair at pilot cap size.
- `roles_from_logs.py` — WP1.3 `RoleGranted` extraction.

**Bucket 3 — accepted-untested (record in proposal §7):** native-client admin behaviour
(burn/seizure of pool balances, node-release semantics). Cannot be triggered or forked; covered by
pilot caps, freeze runbook, issuer confirmation.

### WP4 — Deployment scripts (dry-run only in this plan)

**Status (2026-09-16): written, compile/dry-run pending.** One shared config contract holds every
address and parameter so the scripts cannot drift: `script/CoinbaseEquityBaseConfig.s.sol`
(`_equities()` table, `_validateEquityPool` incl. the `observe([60,0])` gate, `_requireFreshFeed`,
`_logSafeTx`). Scripts: `DeployBaseCoinbaseEquityAdapters.s.sol`, `DeployBaseCoinbaseEquityVault.s.sol`,
`VerifyBaseCoinbaseEquityDeployment.s.sol`, `CoinbaseEquityBorrowLimits.s.sol` (`FreezeBorrows` +
`UnfreezeBorrows`). Adapter addresses flow between scripts as `ADAPTER_<SYMBOL>` env vars (logged by
the adapter script). `foundry.toml` grants no `fs_permissions`, so scripts **log** rather than
`vm.writeJson`; the WP7 manifest is assembled by hand from the logs and checked by the verify script.
Dry-runs must target a **live Base RPC**: the scripts call `multiplier()` on the real B20 tokens,
which reverts on anvil/revm forks.

Two stages, gated separately (§4, §6): **Stage A** deploys everything inert (`globalDebtLimit = 0`,
no `setVault`); **Stage B** configures and enables. Stage A must be complete and verified before any
Stage-B gate is evaluated — the gates are no longer circular.

**`script/DeployBaseCoinbaseEquityAdapters.s.sol`** — deploys **seven** `ChainlinkMultiplierFeed`
(feed, token), asserts `feed()`/`token()`/`decimals()` and that `latestRoundData()` returns
`feed.answer × multiplier / 1e18`, and logs `ADAPTER_<SYMBOL> <address>` for the next script and the
WP7 manifest. No ownership step — the adapters have none.

**`script/DeployBaseCoinbaseEquityVault.s.sol`** — modeled on `DeployAerodromeProtocol.s.sol`.
Preflight (`_validateDeploymentConfig`, all `require`):
- `chainid == 8453`; code at NPM, factory, USDC, UniversalRouter, 0x AllowanceHolder, sequencer
  feed, USDC feed, seven adapters, seven pools, V3Utils, MULTISIG.
- `npm.factory() == MinUnstake factory`; for each pool: `factory.getPool(token, USDC, 10) == pool`,
  `pool.token0() == USDC`, `pool.tickSpacing() == 10`, `pool.nft() == NPM`,
  **`pool.observe([60, 0])` succeeds** (not a cardinality number — see WP0.1).
- For each adapter: `adapter.feed() == expected feed`, `adapter.token() == expected token`,
  `adapter.decimals() == 8`, `adapter.latestRoundData()` succeeds and `updatedAt` within
  `maxFeedAge`; USDC raw feed fresh within 86400.
- `V3Utils(0xc3cF…).owner() == MULTISIG && pendingOwner() == address(0)` (WP0.2 accepted).
Broadcast:
1. `InterestRateModel(0, Q64*13/100, Q64*300/100, Q64*90/100)` **[confirm, §7]**.
2. `V3Oracle(npm, USDC, address(0))`; `setMaxPoolPriceDifference(300)`;
   `setSequencerUptimeFeed(0xBCF8…6433)`; `setTokenConfig(USDC, usdcFeed, 86400, pool=0, 0,
   Mode.CHAINLINK, 0)` (forced for reference token; raw feed, as on every live vault); for each equity
   `setTokenConfig(token, adapter, 108000, pool, 60, Mode.CHAINLINK_TWAP_VERIFY, 300)`.
   **Do not call `setEmergencyAdmin`** — leave `address(0)`, matching the live Aerodrome oracle.
3. `V3Vault("Revert Lend Coinbase Equities USDC", "rlCbEqUSDC", USDC, npm, irm, oracle)`
   **[name/symbol: suggestion]**; `setTokenConfig` for USDC (85%, uncapped) and the seven equities
   (§3 table, **pilot** factors); `setReserveFactor(10%)`; `setReserveProtectionFactor(5%)`;
   `setLimits(1_000e6, 2_000_000e6, 0, 200_000e6, 100_000e6)` — **`globalDebtLimit = 0` at deploy**
   so borrows stay disabled until smoke tests pass; `setTransformer(V3Utils, true)`.
   **Do not call `setEmergencyAdmin`** — leave `address(0)`, matching the live Aerodrome vault.
4. `FlashloanLiquidator(npm, UniversalRouter, 0xAllowanceHolder)` — **no ownership; nothing to
   transfer.**
5. `transferOwnership(MULTISIG)` on IRM (plain `Ownable` → assert `owner() == MULTISIG`), oracle
   and vault (`Ownable2Step` → assert `pendingOwner() == MULTISIG`). Print the Safe batch:
   `oracle.acceptOwnership()`, `vault.acceptOwnership()`.
6. Log everything; append to the manifest JSON.
Stage A ends when the Safe has executed the accept batch and `owner()`/`pendingOwner()` read
MULTISIG/`0` on oracle and vault. Not in the script (multisig-signed, from calldata the script
prints): the accept batch; `V3Utils.setVault(vault)` (owner-only; reuse
`script/ConfigureV3Utils.s.sol`'s calldata output); the Stage-B `setLimits` steps below.

**`script/VerifyBaseCoinbaseEquityDeployment.s.sol`** — read-only, two modes:
- `--stage a` (env `STAGE=a`; after Stage A, before any Stage-B gate): `getPool` resolution ×7;
  `oracle.getTokenValue(token, 1e8, USDC)` per equity (runs all three oracle checks without needing a
  position) within 3% of the adapter answer;
  `observe([60,0])` ×7; sequencer feed; **`emergencyAdmin() == address(0)` on both vault and
  oracle**; `owner() == MULTISIG && pendingOwner() == 0` on vault, oracle, V3Utils; IRM `owner()`;
  adapters have no owner (assert no `owner()` selector); `globalDebtLimit == 0`; all token configs
  == manifest.
- `--stage b` (after the smoke test, before caps are raised): everything above plus the smoke-test
  evidence (tx hashes read from the manifest) and the final limits tuple.
It does **not** simulate borrow/repay/liquidate via `eth_call` — stateless calls cannot chain and
forks cannot execute B20. That is the on-chain smoke test:

**Stage-B on-chain smoke test (real transactions, team-controlled, tiny).** Safe sets
`setLimits(minLoan, lendLimit, globalDebtLimit = 3 × minLoanSize, …)`; a team account deposits a
small B20/USDC position per pair, borrows `minLoanSize`, repays; one position is pushed under the
threshold by borrowing at max and waiting for a feed move (or a temporary CF tweak on that token
config from the Safe — decide in review) and liquidated by the named liquidator (WP5) using `amountIn = 0`
inventory-take; then everything is unwound and `globalDebtLimit` returns to `0` for the weekend
dry-run (§4 #7). Record every tx hash in the manifest. This is the only place borrow → liquidate
is exercised against real B20 semantics before lenders are exposed.

**`script/CoinbaseEquityBorrowLimits.s.sol` (`FreezeBorrows` / `UnfreezeBorrows`)** — `setLimits` is **owner-only**
here (no `emergencyAdmin`) and the owner is the multisig, so these scripts **do not broadcast from
`deployer`**. They read the current tuple and debt, compute the target
`(minLoan, lendLimit, currentDebt, 0, 0)` (freeze) or the manifest tuple (unfreeze), print the exact
Safe calldata (`abi.encodeWithSignature("setLimits(uint256,uint256,uint256,uint256,uint256)", …)`
plus `to`/`value`), and when run against a fork simulate the call and assert that `borrow` reverts
while `repay` and `liquidate` succeed. The runbook (WP6) owns the schedule and the Safe template.

**Update `script/ConfigureV3Utils.s.sol`** only if its `PRIVATE_KEY` requirement blocks the
keystore flow (it currently reads `vm.envUint("PRIVATE_KEY")` — same change as
`DeployBaseV3UtilsNewClFactory` received).

### WP5 — Stressed-exit model (replaces the "25% of pool USDC" cap rule)

`script/sim/tickwalk_exit.py`, reproducible from a pinned block: read `slot0`, `liquidity()`,
`tickBitmap` words around the tick, `ticks(t).liquidityNet`, then simulate crossing with the 0.05%
fee. Scenarios: −10/−20/−30/−40% underlying shocks; positions in-range, narrow, fully equity-side;
pre-gap and post-arbitrage states; single-name and correlated seven-name liquidation; the proposed
cap **plus** liquidation incentive; gas and slippage limits; available liquidator capital. Output:
USDC recovered vs notional per pool per scenario, and **derived pilot caps** with a sensitivity table.
Acceptance: results reproduced by a second run at a different block within stated tolerance; pilot
caps in the manifest either match the model or the divergence is explicitly accepted in §7 of the
proposal.

**Liquidation-readiness gate (added 2026-09-16).** Governance "accepting inventory-only
liquidation" does not create a liquidator, and a live 0x quote today is evidence of today's book,
not the post-gap one. Borrows are not enabled until **one** of these is documented:
1. stressed-exit liquidity demonstrated: WP5 shows cap-sized exits recover ≥ X% (decide X) after a
   −30% gap, on two blocks; **or**
2. a **named, funded liquidator** — account, USDC balance ≥ sum of pilot caps ÷ CF, confirmed B20
   eligibility (non-US KYC / issuer redemption access, since `amountIn = 0` leaves them *holding*
   B20 LP), monitoring hooked up, and a completed smoke-test liquidation (WP4 Stage B); **or**
3. caps re-derived from that liquidator's actual capital rather than from pool depth.
Record which one in the manifest. Half-size caps remain placeholders until then.

### WP6 — Monitoring and runbook: `docs/runbook-coinbase-equity-vault.md`

Sensors:
- **Policy-registry poller** (≥1/min; `script/sim/policy_registry.sh` in loop mode): for each
  token, `policyId(scope)` for all six scopes (detect re-pointing to a new policy); for each id,
  registry `isAuthorized(id, x)` for the vault, oracle, NPM, V3Utils, FlashloanLiquidator, each
  pool and each named liquidator; `policyAdmin(id)` and `pendingPolicyAdmin(id)`. Any `false`, any
  id change, any admin change or pending admin → page + freeze borrows.
- **Transfer canary** every block or ≥1/min (four directions, WP3 bucket 2) — kept as the
  end-to-end check behind the registry poller. Any revert → page + freeze.
- **`multiplier()` poller** on all seven. Any change → page + freeze borrows; check feed freshness
  before unfreezing (the stale-feed-across-the-flip window auto-recovers at the first adjusted print
  — do not "fix" it).
- **Feed age**: alert 12h weekday / 20h weekend; page at 25h. Routine 5–7h intraday staleness is
  normal — do not alert below 12h.
- **Divergence**: |feed−spot| and |feed−TWAP| per name; alert at 50% of thresholds (1.5%).
- **Ring coverage**: alert if any pool's measured observation span < 10× `twapSeconds`.
- **Debt tracking must not use `loanInfo()`**: it values the collateral and reverts for the whole
  blackout (verified in `V3VaultB20.t.sol::testBlackoutTable`). Monitors compute debt as
  `loans(tokenId)` shares × `lastDebtExchangeRateX96 / Q96`, and health from the last good price.
- **Freeze tuple nuance** (verified): `globalDebtLimit = currentDebt` caps *total* debt, so amounts
  repaid during the weekend can be re-borrowed up to the frozen total. Acceptable — net exposure
  cannot grow — but the runbook should say so rather than promise "no borrowing".
- **Cross pairs**: enumerate deposited positions nightly; alert on any position whose two legs are
  both equities (see §2.8) and report its debt against both caps.
Freeze procedure: responsible account/automation; exact five-tuples before/after; **Friday 15:00 ET**
deadline; NYSE holiday and early-close calendar; per-name halt logic; success/failure/missed-tx
monitoring; restoration = first post-closure print **and** |feed−TWAP| < 2% sustained; manual
fallback owner; pre-weekend scan of loans near threshold. State that deposits cannot be frozen. **There is no
`emergencyAdmin`**: the freeze and the unfreeze are each a multisig `setLimits` transaction, so the
runbook must name the **weekend signing quorum** (who is on call at Friday 15:00 ET and Sunday
evening), the Safe transaction template, and what happens if quorum is missed — borrows stay open
into the blind window and the pre-weekend near-threshold scan becomes the only defence. Optional
follow-up, out of pilot scope: a narrowly-scoped Safe module or scheduled transaction limited to the
two tuples. Incident procedures: feed failure, corporate action, issuer policy change, failed/late
liquidation, lender run during blackout.
Acceptance: the freeze/unfreeze cycle is **exercised through one full weekend** on the deployed
(borrow-disabled) vault before borrows are enabled, with logs attached.

### WP6b — Equity/equity cross pairs (decision, not a frontend setting)

`_calculateTokenCollateralFactorX32` takes `min(CF0, CF1)` and `V3Vault` has **no pool or pair
allowlist** — eligibility is per token. Any MinUnstake NFT pairing two configured equities is
depositable through `create`, permissionlessly, whatever the frontend shows. Crosses are *strictly
riskier* than equity/USDC: no USDC leg, so the √price cushion of an in-range USDC pair is gone and
both legs fall together in a correlated crash; both legs also blackout together. Seven tokens →
21 possible pairs. **Decided (Mario, 2026-09-16): accept and monitor.** The two options were:
- **Accept and monitor**: no code change; the per-name caps already bind both legs; WP6 cross-pair
  sensor; state it in the proposal as an accepted risk.
- **Exclude**: add a pool/pair allowlist to `V3Vault` (checked in `_updateAndCheckCollateral` or at
  `create`) — a **change to the audited vault**, needs review, and is a Stage-A design input.
"Don't surface it in the frontend" is not a control and is removed as an option.

### WP7 — Manifest and go/no-go

`deployments/base-coinbase-equity.json` — machine-readable: chain, block, every contract
(address, constructor args, owner, pendingOwner, emergencyAdmin — `FlashloanLiquidator` has none),
every `setTokenConfig` tuple (oracle and vault), limits tuple, adapter feed/token linkage (seven),
pool/feed/token linkage, policy ids + admin observed, named liquidator, smoke-test tx hashes,
tx hashes, dates.
`VerifyBaseCoinbaseEquityDeployment.s.sol` reads it and asserts every postcondition.
Also: the gap-history reproduction (WP1.5) as a notebook/script + CSV under `script/sim/`, and the
legal sign-off reference.

---

## 3. Parameter manifest (exact on-chain values)

| Parameter | Value | Encoded | Source |
| --- | --- | --- | --- |
| Chain | Base | 8453 | — |
| NPM | MinUnstake | `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | proposal §2.3 |
| CL factory | MinUnstake | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | §2.3 |
| Lending asset / referenceToken | USDC (6 dec) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | §3.1 |
| `_chainlinkReferenceToken` | none | `address(0)` | §3.1 (hard-coding USDC=$1 rejected) |
| USDC feed | Chainlink USDC/USD, raw | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | §2.5 — as on every live vault; garbage prints caught by equity TWAP divergence |
| Sequencer uptime feed | Base | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | live rlAeroUSDC |
| UniversalRouter | Aerodrome | `0x6Cb442acF35158D5eDa88fe602221b67B400Be3E` | cannot reach MinUnstake pools |
| 0x AllowanceHolder | | `0x0000000000001fF3684f28c67538d4D072C22734` | — |
| V3Utils (reuse) | MinUnstake-bound | `0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD` | `Ownable2Step`: transfer + Safe accept first |
| Owner — vault, oracle, IRM (`FlashloanLiquidator` and the 7 adapters have no owner) | **2-of-3 Safe (decided: option A, as rlAeroUSDC)** | `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9` | GnosisSafeProxy v1.3.0, verified; vault/oracle `Ownable2Step` → Safe must `acceptOwnership()`; IRM plain `Ownable` |
| Policy registry (B20) | precompile | `0x8453000000000000000000000000000000000002` | `isAuthorized(uint64,address)`, `policyAdmin`, `policyExists`, `pendingPolicyAdmin` |
| Transfer/mint policy id (all tokens, 09-16) | blocklist | `5`; admin `0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812` (EOA) | WP1.3 / WP6 poller |
| `emergencyAdmin` (vault + oracle) | not set | `address(0)` | matches live rlAeroUSDC + oracle; `setLimits`/`setOracleMode` multisig-only |
| Oracle `maxPoolPriceDifference` | 3% | `300` | §3.1 |
| Equity oracle mode | `CHAINLINK_TWAP_VERIFY` | enum | §3.1 |
| Equity `twapSeconds` | 60 s | `60` | §3.1 (a 360 ring cannot fail a 60 s window; see WP0.1) |
| Equity `maxFeedAge` | 30 h | `108000` | §3.1 (>24h weekday gaps, <52.45h weekend) |
| Equity `maxDifference` | 3% | `300` | §3.1 — never above; validate overnight |
| USDC oracle mode | `CHAINLINK` (forced) | enum | `setTokenConfig` L261–278 |
| USDC `maxFeedAge` | 24 h | `86400` | house convention |
| IRM | base 0, mult 13%, jump 300%, kink 90% | `0, Q64*13/100, Q64*300/100, Q64*90/100` | live Aerodrome; **confirm** |
| Reserve factor | 10% | `429496729` | house |
| Reserve protection factor | 5% | `214748364` | house |
| CF USDC | 85% | `3650722201` | live |
| CF AAPLc MSFTc GOOGLc AMZNc METAc | **55%** | `2362232012` | §4.2 (ramp 60%) |
| CF NVDAc TSLAc | **50%** | `2147483648` | §4.2 (ramp 55%) |
| Cap GOOGLc (pilot / full) | 6% / 12% of lent | `257698037` / `515396075` | §4.3 |
| Cap METAc | 4.5% / 9% | `193273528` / `386547056` | §4.3 |
| Cap AAPLc | 4% / 8% | `171798691` / `343597383` | §4.3 |
| Cap NVDAc | 3.5% / 7% | `150323855` / `300647710` | §4.3 |
| Cap MSFTc | 2.5% / 5% | `107374182` / `214748364` | §4.3 |
| Cap AMZNc | 2% / 4% | `85899345` / `171798691` | §4.3 |
| Cap TSLAc | 1.5% / 3% | `64424509` / `128849018` | §4.3 |
| Cap USDC | uncapped | `4294967295` | — |
| `setLimits` at deploy (Stage A) | borrows disabled | `(1_000e6, 2_000_000e6, 0, 200_000e6, 100_000e6)` | §4.4 |
| `setLimits` smoke test (Stage B) | tiny | `(1_000e6, 2_000_000e6, 3 × minLoanSize, 200_000e6, 100_000e6)` | WP4 smoke |
| `setLimits` live | | `(1_000e6, 2_000_000e6, 1_000_000e6, 200_000e6, 100_000e6)` | §4.4; `minLoanSize` to be derived |
| `setLimits` weekend freeze | | `(1_000e6, 2_000_000e6, currentDebt, 0, 0)` | WP4/WP6 — verify in WP3 |
| Pool cardinality | optional | `2048` on the three 360-ring pools, if bumped at all; gate is `observe([60,0])` + span ≥ 10× | WP0.1 |
| Cross pairs (equity/equity) | accept + monitor (decided) | no allowlist; caps bind both legs; nightly scan | WP6b |
| Named liquidator | account, capital, B20 eligibility | **TBD** | WP5 gate |
| Reserve seed | ≥ $40–100K or explicit acceptance | **TBD** | §7 |

Feed, token and pool addresses per asset are in proposal §2.1, §2.3, §2.5.

---

## 4. Deployment transaction order (for the day; each step gated on the previous)

| # | Stage | Action | Signer | Gate |
| --- | --- | --- | --- | --- |
| 0 | pre | *(optional)* `increaseObservationCardinalityNext(2048)` on the three 360-ring pools | anyone (`deployer`) | if chosen; weeks before |
| 1a | pre | V3Utils `transferOwnership(MULTISIG)`; assert `pendingOwner()` | `deployer` (current owner) | — |
| 1b | pre | V3Utils `acceptOwnership()`; assert `owner()==MULTISIG`, `pendingOwner()==0` | **multisig** | 1a |
| 2 | A | Deploy 7 adapters (ownerless); assert linkage and `answer × multiplier` | `deployer` | WP2 reviewed; §6 Stage-A gates |
| 3a | A | Deploy IRM (transfer → immediate), Oracle (configured), Vault (configured, **debt limit 0**), FlashloanLiquidator (no owner); `transferOwnership` on oracle + vault; assert `pendingOwner()` | `deployer` | WP4 dry-run green; preflight passes at deploy block; 2 |
| 3b | A | `acceptOwnership()` on oracle + vault (Safe batch) | **multisig** | 3a |
| 4 | A | `VerifyBaseCoinbaseEquityDeployment --stage a` | read-only | 3b; all green |
| 5 | B | `V3Utils.setVault(vault)` | **multisig** | 1b, 4 |
| 6 | B | **On-chain smoke test**: `setLimits(…, 3 × minLoanSize, …)`; deposit/borrow/repay per pair; one real liquidation by the named liquidator; unwind; `setLimits(…, 0, …)` | **multisig** + team accounts + liquidator | 5; WP5 liquidator gate |
| 7 | B | Enable monitoring (incl. policy-registry poller); **run one full weekend** with borrows disabled; exercise freeze/unfreeze tuples | ops + **multisig** (each `setLimits` is a Safe tx) | 6; logs attached |
| 8 | B | `VerifyBaseCoinbaseEquityDeployment --stage b`; `setLimits(..., globalDebtLimit = 1_000_000e6, ...)` — borrows open at pilot caps | **multisig** | §6 Stage-B gates all green |
| 9 | post | After ≥4 clean weekends + seeded reserves: evaluate CF/cap ramp | multisig | monitoring data |

---

## 5. Definition of done for *this plan* (before any deployment)

- WP0.1 decided (bump to 2048 or skip) and, if bumped, verified; `ring_coverage.sh` green either way.
- WP0.2 verified on-chain: `owner() == MULTISIG && pendingOwner() == 0` on V3Utils `0xc3cF…`.
- WP1 items 1–5 recorded with sources; design branch (adapter vs raw feeds) chosen accordingly.
- WP2 merged with an independent review comment on the exact diff.
- WP3 bucket 1 green in CI; bucket 2 scripts runnable and outputs committed under `script/sim/out/`
  for a pinned block; bucket 3 recorded.
- WP4 scripts dry-run green against live Base at a recent block (`forge script … --rpc-url …`
  without `--broadcast`), preflight assertions all passing.
- WP5 model reproduced at two blocks; pilot caps in manifest justified by it or divergence accepted;
  liquidation-readiness route (1/2/3) chosen and, if (2), the liquidator named.
- WP6 runbook written; freeze/unfreeze scripts dry-run; policy-registry poller runs against live Base.
- WP6b: accept+monitor recorded; cross-pair scan in the runbook.
- WP7 manifest schema filled with everything known pre-deploy; go/no-go list (§6) instantiated.
- Proposal §7 updated: every [assumption] either converted to [verified] or moved to [accepted risk]
  with owner; every [blocker] either closed or explicitly blocking deployment.

---

## 6. Go / no-go (each item independently verifiable on-chain or by attached artefact)

Two gates. **Stage A** (inert deployment: `globalDebtLimit = 0`, no `setVault`) exposes no lender
and requires only what can be known *before* anything is on chain. **Stage B** (enable borrows)
requires evidence that can only come *from* the Stage-A deployment. Nothing in Stage A may depend on
a Stage-B artefact.

**Stage A — no deployment until all are true:**

- [ ] `ring_coverage.sh`: `observe([60,0])` succeeds on all seven pools at a recent block; measured
      span ≥ 10× `twapSeconds` (cardinality bump optional, recorded either way)
- [ ] Chainlink feed units confirmed **in writing** (share-basis vs token-basis)
- [ ] Coinbase multiplier ≠ balance scaling confirmed **in writing**; change-control documented
- [ ] Issuer policy/role/pause/burn/seizure enumeration complete via registry + logs on all seven;
      policy-admin EOA `0xEC0F05…2812` control explained by Coinbase; consequences formally accepted
      (or exclusion chosen)
- [ ] `ChainlinkMultiplierFeed` (multiplier only, ownerless) merged, independently reviewed,
      matrix tested; garbage-print divergence tests (equity and USDC) green
- [ ] `twapSeconds`, `maxDifference`, `maxPoolPriceDifference`, `maxFeedAge` pinned; overnight
      divergence samples support `maxDifference = 300`
- [ ] Cross-pair handling recorded as accepted risk in the proposal; nightly scan specified in runbook
- [ ] Explicit CF line (55/50 launch; ramp conditions) recorded
- [ ] `minLoanSize` derived from measured gas + stressed exit; IRM parameters confirmed
- [ ] V3Utils `0xc3cF…`: `owner() == MULTISIG && pendingOwner() == 0`
- [ ] Deploy scripts dry-run green at a recent block, incl. `pendingOwner` assertions and printed
      Safe accept batches
- [ ] Legal approval recorded

**Stage A complete when:** all contracts deployed; every `acceptOwnership` executed; `Verify --stage a`
green; `emergencyAdmin() == address(0)` on vault and oracle; `globalDebtLimit == 0`.

**Stage B — borrows stay disabled until all are true:**

- [ ] `V3Utils.setVault` executed by the Safe
- [ ] **On-chain smoke test** completed at `globalDebtLimit = 3 × minLoanSize`: deposit / borrow /
      repay per pair and **one real liquidation** by the named liquidator; tx hashes in manifest;
      limit returned to `0`
- [ ] Liquidation readiness satisfied by **one** of: demonstrated stressed-exit liquidity (WP5),
      a **named, funded, B20-eligible liquidator** who performed the smoke liquidation, or caps
      re-derived from liquidator capital — "inventory-only accepted" alone does **not** pass
- [ ] Caps supported by WP5 stressed-exit model, or half-size pilot explicitly accepted *and* the
      liquidator gate above passed
- [ ] Reserve seeding done (amount, funder) or first-loss socialisation explicitly accepted
- [ ] Freeze/unfreeze **exercised over one full weekend on the deployed vault**; runbook names
      accounts, tuples, deadline, calendar, restoration, fallback
- [ ] **Multisig weekend signing quorum committed** for Friday freeze / Sunday unfreeze, with a
      tested Safe tx template
- [ ] Monitoring live: policy-registry poller, canary, multiplier poller, feed age, divergence,
      ring coverage, cross-pair scan
- [ ] `Verify --stage b` green; manifest complete; independent reviewer has checked final commit,
      manifest, simulation output, smoke-test hashes and deployed bytecode

If any item cannot be satisfied: smaller pilot, different parameters, different design, or
cancellation. **Do not force a deployment recommendation.**

---

## 7. Decisions required from Mario (block specific WPs)

| Decision | Blocks | Default if none |
| --- | --- | --- |
| ~~Vault owner: Safe or 48h timelock?~~ **Decided: A — Safe `0x45B22086…1cc9`, no timelock, `emergencyAdmin = none` (all as rlAeroUSDC).** Option C (48h timelock owner + Safe as `emergencyAdmin`) is the recorded candidate for post-pilot hardening before caps are raised | WP4, WP6 | — |
| Weekend multisig signing quorum (Friday 15:00 ET freeze, Sunday-evening unfreeze) — `emergencyAdmin` itself is decided: none | WP6 | — |
| Reserve seed amount and funder (≥ $40–100K suggested) | #7 in §4 | explicit first-loss acceptance |
| ~~Adapter answer bounds (equity + USDC)~~ **Decided: none** — redundant with TWAP divergence; matches live vaults | — | — |
| ~~Cross pairs~~ **Decided: accept + monitor** (no allowlist at pilot; caps bind both legs; nightly scan) | — | — |
| **Named liquidator** (account, capital, B20 eligibility) — or which WP5 route replaces it | WP5, Stage B | none → Stage B blocked |
| Cardinality bump on the three 360-ring pools: do (2048) or skip | WP0.1 | skip |
| IRM parameters (reuse Aerodrome `0/13%/300%/90%`?) | WP4 | reuse |
| Vault name/symbol | WP4 | `Revert Lend Coinbase Equities USDC` / `rlCbEqUSDC` |
| Pilot at half caps (§4.3) or WP5-derived caps | WP4 | half caps |
| Who broadcasts WP0.1 (permissionless) | WP0 | `deployer` |
