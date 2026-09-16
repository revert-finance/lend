# Independent review addendum: Coinbase B20 equity collateral vault (Base)

**Status:** review findings, to be merged into the final deployment plan.
**Date:** 2026-09-15/16. All on-chain measurements taken at ~block 51,362,594 unless noted.
**Relationship to other documents:** this file is the third input alongside
`docs/proposal-coinbase-equity-collateral-base.md` (mechanism analysis and parameters) and
`docs/prompt-coinbase-equity-collateral-base-deployment-readiness.md` (process and go/no-go).
Where this file conflicts with either, the evidence below wins. Where they already cover an item,
this file references rather than repeats.

Reviewed: `src/V3Vault.sol`, `src/V3Oracle.sol`, `src/utils/Swapper.sol`,
`src/utils/FlashloanLiquidator.sol`, `src/transformers/V3Utils.sol`, `src/GaugeManager.sol`,
deploy scripts, `docs/agents/*`, and live Base state for all seven tokens, feeds, pools, and gauges.

---

## 1. Measured on-chain evidence

### 1.1 B20 token surface

- Code is a single byte `0xef` on all inspected tokens; token logic is in the Base execution
  client. **Consequence verified empirically: vanilla anvil/revm forks cannot execute B20
  calls** — `transfer` reverts on a local fork while the identical `eth_call` against a live
  Base node returns `true`. This constrains what "fork testing" can mean (§6).
- Callable surface probe (NVDAc and GOOGLc): `multiplier()` works. `uiMultiplier()`,
  `newUIMultiplier()`, `effectiveAt()`, `isAuthorized(uint256,address)`,
  `policyAdmin(uint256)`, `policyType(uint256)`, `getPolicy(uint256)` each revert returning
  *their own 4-byte selector* (verified against computed selectors) — the native client's
  "function not implemented" convention. **`isAuthorized` is not callable for any policy ID
  tried (0 and 5)**: the gating state is not pollable via view calls. OZ-style `RoleGranted`
  events are visible at token initialization, so roles are enumerable from logs, but scope
  semantics and blocklist membership are not.
  → The readiness doc's §2 enumeration cannot be completed from chain state alone; it requires
  issuer disclosure + event archaeology. The only *live* gating sensor is a simulated-transfer
  canary (§5).
- **Multipliers (live reads, 2026-09-15):** GOOGLc = `1000377118676784179` (a dividend already
  processed through the instant `updateMultiplier` path — confirms the readiness doc's claim and
  proves multiplier updates are *routine*, not tail events). All other six = `1e18`.
  Dividend-sized changes (~0.04%) sit far below the proposed 3% divergence tolerance and are
  benign even unhandled; splits are the bricking case; emergency cuts are the dangerous case.

### 1.2 Chainlink feed behavior (NVDA aggregator `0xF72B…9675`, round walk)

| Event | Round | Answer | Time (UTC) |
| --- | --- | --- | --- |
| Last pre-weekend print | 346 | $218.28 | Fri 09-11 19:33 (15:33 ET) |
| First post-weekend print | 347 | $215.70 | Mon 09-14 00:00 (**Sun 09-13** 20:00 ET) |

Weekend gap = 52.45h, confirmed (the proposal's "Sun 2026-09-14" is a typo; the gap itself is
real). Weekday gap round 360→361 = 16.8h, confirmed. At review time (Tue 21:57 UTC) the feed's
last print was 14:52 UTC — **7.1h stale, having gone quiet mid-session**. Multi-hour intraday
staleness is routine; alert thresholds must account for it (§5). USDC/USD feed
(`0x7e86…bc6B`) read 0.99987113, ~9h old at sample time.

### 1.3 Pools: cardinality, coverage, configuration

All seven pools: `token0 = USDC`, `tickSpacing = 10`, fee 0.05%. The oracle's Slipstream
`getPool(tokenA, tokenB, tickSpacing)` resolution was executed live and returns the correct pool
for these pairs; the MinUnstake NPM `positions()` decodes into the 12-field layout
`_loadPositionState` expects.

| Pool | cardinality | cardinalityNext | ring coverage at sample (quiet Tue) | worst case at 2s blocks (touched every block) |
| --- | --- | --- | --- | --- |
| GOOGLc | 2048 | 2048 | hours | ~68 min |
| METAc | 2048 | 2048 | hours | ~68 min |
| AAPLc | 2048 | 2048 | hours | ~68 min |
| NVDAc | 2048 | 2048 | ~3.4h+ | ~68 min |
| MSFTc | **360** | **360** | ~5.1h | **~12 min** |
| AMZNc | **360** | **360** | ~4.2h | **~12 min** |
| TSLAc | **360** | **360** | ~3.6h | **~12 min** |

TSLAc at 360 is new information (the proposal had it unmeasured — there are **three** 360 pools,
not two). `cardinalityNext == cardinality` everywhere: nobody has requested an increase.
Observations write at most once per *touched block*; `V3Oracle._getReferencePoolPriceX96` calls
`pool.observe` **unguarded** (no try/catch — by design, fail-closed), and `observe(N)` reverts
when the ring doesn't reach back N seconds. Failure timing is adverse: coverage collapses toward
the worst case exactly during high-activity windows (Monday reopens, crashes), freezing
liquidations — not just borrows — for the duration of the frenzy, recovering only when trading
calms. See §2.1.

Pool USDC balances at sample (drifted from the proposal's snapshot; re-measure at deploy):
GOOGLc $1,102,397 · METAc $745,535 · AAPLc $987,881 · NVDAc $694,366 · MSFTc $414,477 ·
AMZNc $378,554 · TSLAc $351,272.

### 1.4 Exit liquidity, measured by tick-walk of the live bitmap

Method (reproducible): read `slot0`, `liquidity()`, `tickBitmap` words around the current tick,
`ticks(t).liquidityNet` for initialized ticks, then simulate crossing with the 0.05% fee.
Two legs: (1) gap trade moving the equity price −30%; (2) liquidator exit of the proposed
per-name cap in token1 from the post-gap state.

- **At-spot** cap-sized sells: 0.1–0.6% impact. Deceptive — nearly all liquidity sits within a
  few percent of spot.
- **The −30% gap leg itself** absorbs $0.36M–$1.06M of token1 selling per pool (vault LP
  collateral is the counterparty absorbing this — the LVR the proposal's Q4 names).
- **Post-gap cap-sized exit recovers 4–12% of notional:**

| Pool | cap | USDC recovered | vs post-gap market |
| --- | --- | --- | --- |
| GOOGLc | $240,000 | ~$15,800 | −93% |
| METAc | $180,000 | ~$22,000 | −88% |
| AAPLc | $160,000 | ~$9,700 | −94% |
| NVDAc | $140,000 | ~$10,900 | −92% |
| MSFTc | $100,000 | ~$4,000 | −96% |
| AMZNc | $80,000 | ~$3,900 | −95% |
| TSLAc | $60,000 | ~$3,800 | −94% |

→ In the scenario §3.3 of the proposal sizes against, **the pool is not the exit**. Post-gap
liquidation is viable only for desks with issuer redemption (non-US KYC) or TradFi hedging
(futures reopen Sunday 18:00 ET, before the feed resumes). The liquidation penalty band is
hard-coded at 2–10% (`MIN/MAX_LIQUIDATION_PENALTY_X32` are contract constants, not per-vault
configurable); 2% does not compensate weekend inventory risk, so expect liquidations to clear
late in the band — effective protection is thinner than the nominal 30.9pp.

### 1.5 Gauges, ownership, house conventions

- Gauges exist per equity pool (e.g. NVDAc `0x30d1E5…771A8`). They are EIP-1167 proxies to
  implementation `0x434bccab…f90f7b`; disassembly of the implementation contains **zero
  `TIMESTAMP` opcodes** → no unstake time-lock; staked collateral cannot be delay-trapped by
  the gauge. (Reward-flow behavior of this gauge variant still needs one live-node simulation
  before wiring a GaugeManager; also note the known unstake gas-bistability OOG issue from
  `docs/investigation-aerodrome-stuck-unstake-71869354.md`.)
- **V3Utils MinUnstake (`0xc3cFFd…Fe2dD`) owner is still the hot automation EOA
  `0x83681C…eA5C`** — the open item in `script/DEPLOY_AERODROME_V3UTILS.md` is unresolved.
  Blocking before any vault wiring (it controls `setVault` and stuck-token withdrawal).
- Live rlAeroUSDC oracle (`0x8272…0952`) conventions: `maxPoolPriceDifference = 200`;
  twapSeconds 60; maxDifference 200; USDC maxFeedAge 86400; sequencer feed
  `0xBCF8…6433` (matches the proposal's §3.2).
- **C4 #446 is unfixed in this tree**: `_getChainlinkPriceX96` enforces only `answer <= 0` and
  staleness. The proposal's prerequisite is real.
- Current `setTokenConfig` source forces `Mode.CHAINLINK` for the reference token, so a deploy
  from this tree puts USDC in CHAINLINK-only mode (the live oracle has USDC in
  CHAINLINK_TWAP_VERIFY). Consistent with the proposal — confirm it is deliberate.
- `create`/`onERC721Received` never touches the oracle → **deposits work during blackouts**;
  only borrows and valuation-gated paths freeze. Corrects the proposal §2.2 table.
- `V3Utils` routes **every** swap through `_routerSwap` (0x AllowanceHolder or the Aerodrome
  UniversalRouter). The UniversalRouter is pinned to the original CL factory + v2
  (`script/DEPLOY_AERODROME_V3UTILS.md`) and cannot touch MinUnstake pools, where all B20/USDC
  liquidity lives. `FlashloanLiquidator`'s exit legs have the same dependency; `amountIn = 0`
  (inventory take) works without any router.
- `_updateAndCheckCollateral` attributes full debt to both legs of a pair — so any MinUnstake
  pair of two configured tokens (equity/equity crosses) becomes borrowable collateral
  permissionlessly once pools exist. Caps still bind both legs; decide SPA surfacing and note it.

---

## 2. Issues, severity-ranked

### 2.1 High — observation cardinality vs 2-second blocks (liveness)

Three pools at cardinality 360 (§1.3). Under sustained every-block activity their history is
~12 minutes; `observe(twapSeconds)` reverts for any window longer than the ring; the oracle then
freezes **liquidations during exactly the stress windows it is needed**. Not a mispricing risk —
a liveness failure with adversarial timing, plus a cheap griefing flavor (dust-swap every block
to prolong it).

**Required:**
1. Call `increaseObservationCardinalityNext(4320)` on all seven pools **immediately** —
   permissionless, cheap; new slots only populate from future touches, so this cannot wait until
   deploy week.
2. Pin `twapSeconds` in the deployment manifest. Recommend **60s** at launch (house convention;
   survives even a 360 ring at 12-minute worst case; loses nothing for a ±3% sanity cross-check).
   Raise to 300–600s only after the grown rings have demonstrably covered that window under
   observed worst-case touch rates.
3. Deploy-script precondition: assert `observationCardinality ≥ required` per pool, like the
   V3Utils script asserts pool linkage.

### 2.2 High — B20 issuer action inside the blackout fails open today; the multiplier-aware feed leg closes it

Current design values `rawUnits × sharePrice` and never reads `multiplier()`. An emergency
`updateMultiplier` cut **with transfer gating on a weekend** leaves the feed frozen (≤30h fresh)
and the pool untradeable (TWAP frozen): both checks pass while collateral is impaired, and
deposits remain open (§1.5), so impaired LP can be deposited and borrowed against. This is the
one identified *fail-open* path.

**Required: the feed adapter** (preferred over an ops-only runbook — it is automatic):

```
ChainlinkMultiplierFeed.latestRoundData()
    = feed.latestRoundData() with answer := answer × token.multiplier() / 1e18
```

Point `setTokenConfig` at the adapter instead of the raw feed. `V3Oracle` only ever calls
`decimals()` and `latestRoundData()`, so the adapter is ~30 lines and no audited code changes.
Behavior across scenarios (each must be a test):

| Scenario | Adapter behavior | Outcome |
| --- | --- | --- |
| Normal / dividend (Δmult ≈ 0.04%) | tracks; error ≪ 3% | uninterrupted |
| Split 2:1 over a weekend | feed stale at pre-split $200 × mult 2 = $400 vs pool $200 | divergence reverts → bounded outage, **auto-recovers at first adjusted print** ($100×2=$200), no ops action |
| Reverse split | symmetric | as above |
| Emergency cut + gating (weekend) | feed side halves instantly vs frozen pool TWAP | divergence reverts → **fail-closed; the §2.2 hole is closed** |
| Fat-fingered multiplier | passes only if error < maxDifference | keep maxDifference ≤ 300 — it doubles as the silent-error tolerance |
| `multiplier()` itself reverts (client regression) | adapter reverts | fail-closed (must be tested) |

Two prerequisites are binary and external, and gate the whole design:
1. **Feed units**: written confirmation from Chainlink that the `Coinbase TICKER` feeds are
   share-basis (adjusted at corporate actions). If they are token-basis, the adapter
   double-counts and the current config is already correct — the answer flips the design.
2. **Balance semantics**: written confirmation from Coinbase that `multiplier` never scales
   `balanceOf`/`transfer` (redemption-layer only). If balances can mutate, v3 pool accounting
   breaks and the collateral type is undeployable regardless of oracle design.

When the #446 bounds fix lands, apply min/max bounds **in share terms inside the adapter, before
multiplying** — otherwise bounds drift with every split.

### 2.3 High — exit-liquidity reality (§1.4) must recalibrate caps rationale and CFs

Keep the per-name caps — they bound single-name concentration and TWAP-manipulation profit —
but re-justify them as such; the "25% of pool USDC side" rule is cosmetic post-gap (4–12%
recovery measured). Readiness §5's stressed-exit derivation replaces the sizing rule.

**CF recommendation: one notch below the proposal at launch** — 55% for
AAPLc/MSFTc/GOOGLc/AMZNc/METAc and 50% for NVDAc/TSLAc (X32: 55% = `2362232012`,
50% = `2147483648`). Rationale: the binding tail is issuer/wrapper failure (§2.2, unbounded by
equity gap history), liquidator compensation is a hard-coded 2–10% against measured near-zero
post-gap exit, and the market is three weeks old with zero accrued reserves. Raise with evidence
after several weekends of clean operation. The readiness doc's go/no-go conditions currently
constrain caps but never CFs — add a CF line.

### 2.4 Medium — `maxPoolPriceDifference` is unchosen

Absent from the proposal; listed but unmotivated in the readiness doc. It is a **spot**-vs-derived
check that fires before the 3% TWAP divergence on books this thin: blackouts start earlier than
modeled and Sunday/Monday reopen wicks extend them until convergence. House convention is 200.
**Recommend 300 for this deployment**, with the consequence written into the runbook (blackout
start = min(spot drift, TWAP divergence, 30h staleness)) and reopen-wick scenarios in testing.
Note the corollary: switching a token to CHAINLINK-only mid-crisis does **not** remove this
check — the escape hatch is narrower than it looks.

### 2.5 Medium — B20 exit routing depends entirely on 0x

§1.5: UniversalRouter cannot reach MinUnstake pools; `V3Utils` has no same-pool swap path.
**Go-live item:** a verified live 0x AllowanceHolder quote for each B20↔USDC pair, or an
explicitly accepted launch state of inventory-only liquidation (`amountIn = 0`) and degraded
transforms (no compounding). If B20 gating is ever activated, 0x settlement reverts mid-flight —
expect noise, not loss. Readiness §5's exit simulations must simulate the venue the liquidator
contract can actually reach.

### 2.6 Medium — ownership and ops prerequisites

- Transfer V3Utils `0xc3cFFd…Fe2dD` to the approved multisig and verify on-chain **before**
  `setVault` + vault transformer authorization (readiness §8 covers this; keep it blocking).
- `emergencyAdmin` can rewrite *all* vault limits, not just pause borrows — its key needs a
  documented security model and **weekend coverage**, since every identified action (freeze,
  canary response, mode switch) happens on weekends.
- Reserves start at zero: first loss socializes directly to lenders. Either seed a
  protocol-owned reserve at launch (suggest ≥ 2–5% of the $2M lend cap) or write the acceptance
  explicitly. Readiness §6 demands this specification; make the number concrete.
- `minLoanSize`: $100 fails readiness §7's purpose — a 2% penalty on $100 is $2 against real
  exit costs. Recommend ≥ $1,000, derived properly from measured gas + stressed exit cost.
- `setGaugeManager` is one-shot with no binding handshake (accepted in `docs/agents/risk-and-
  acceptability.md`); if staking is enabled, verify the GaugeManager↔vault binding before the
  call and simulate the MinUnstake gauge reward flow once on the live node.

### 2.7 Low — proposal text corrections (fold into the final plan)

- §2.2: "open new loan / add position — frozen" is half-wrong: deposits never touch the oracle.
  Runbook-relevant: the Friday freeze cannot stop collateral pre-positioning (borrowing only
  resumes when prices are live and agreeing, so this is accuracy, not risk).
- §3.3: "The $1M global debt limit binds before the $960K sum of per-name caps" is backwards —
  the caps bind first. Both ceilings existing is correct.
- §1.3: "Sun 2026-09-14 20:00 ET" → Sep 13 (Sep 14 is a Monday).
- §5: cardinality is now measured for all pools — three at 360 (§1.3).
- The §2.1 divergence table is a single regular-hours snapshot; same-evening spot check showed
  the NVDA feed 7.1h stale. Complete the overnight-session sampling before fixing
  `maxDifference = 300`; do not exceed 300 regardless (§2.2 tolerance argument).

---

## 3. Recommended parameter table (delta vs proposal §3.2/§3.3)

| Parameter | Proposal | Recommendation | Why |
| --- | --- | --- | --- |
| Collateral factor (5 mega-caps) | 60% | **55%** (`2362232012`) | §2.3 |
| Collateral factor (NVDAc, TSLAc) | 55% | **50%** (`2147483648`) | §2.3 |
| CF ramp | — | raise toward 60/55 after ≥4 clean weekends + seeded reserves | evidence-based |
| `maxFeedAge` (equities) | 108000 (30h) | **108000** — endorse | clears 24h heartbeat + margin; < 52.5h weekend gap |
| `twapSeconds` | unstated | **60**, pinned in manifest | §2.1 |
| `maxDifference` | 300 | **300**, validated on overnight samples; never above | §2.2, §2.7 |
| `maxPoolPriceDifference` | absent | **300**, consequence documented | §2.4 |
| `observationCardinality` (7 pools) | unaddressed | **≥ 4320**, bumped immediately, asserted at deploy | §2.1 |
| Per-name caps | % of pool USDC side | keep numbers as **concentration limits**; re-derive via readiness §5 stressed exits; consider half-size pilot until reserves exist | §1.4, §2.3 |
| `minLoanSize` | $100 | **≥ $1,000** (derive from measured gas + stressed exit) | §2.6 |
| Reserves | unspecified | seed ≥ $40–100K protocol-owned, or explicit acceptance of first-loss socialization | §2.6 |
| USDC mode | CHAINLINK | CHAINLINK (forced by current source) — confirm deliberate | §1.5 |
| Sequencer feed | `0xBCF8…6433` | unchanged — verified against live deployment | §1.5 |

---

## 4. Ordered pre-deploy actions (time-sensitive first)

1. **Now:** `increaseObservationCardinalityNext(4320)` on all seven pools (permissionless;
   accrues forward only). Verify `observationCardinalityNext` reflects it.
2. **Now:** transfer V3Utils `0xc3cFFd…Fe2dD` ownership to the multisig; verify `owner()` on-chain.
3. **Before any code:** written confirmations — (a) Chainlink feed units (share-basis?);
   (b) Coinbase B20 multiplier semantics (`balanceOf` not multiplier-scaled; change-control
   process); (c) issuer policy/role/seizure enumeration (readiness §2) — on-chain views do not
   exist for this (§1.1).
4. Implement `ChainlinkMultiplierFeed` + the #446 bounds (share-terms, inside the adapter);
   independent review of the exact diff.
5. Verify 0x B20↔USDC quotes per token, or formally accept inventory-only liquidation and
   degraded transforms at launch (§2.5).
6. Build and **exercise** the monitoring + freeze automation through one full weekend before
   enabling borrows (§5).
7. Deploy oracle + vault; run the §7 smoke tests on the live deployment; only then set token
   configs/limits and enable borrows at pilot caps.
8. After ≥4 clean weekends: evaluate CF/cap ramp with the monitoring data collected.

---

## 5. Monitoring and freeze specification (new content; readiness #5 runbook consumes it)

Sensors (the only ones available — §1.1 proved policy state is not pollable):

- **Transfer canary**, every block or ≥1/min, via `eth_call` with `from` overrides: pool → fresh
  EOA; pool → vault address; NPM → FlashloanLiquidator address; fresh EOA → pool. Any revert =
  gating event → page + freeze. Today all return `true` (verified).
- **`multiplier()` poller** on all seven tokens. Any change → page + freeze borrows; check feed
  freshness before unfreezing (stale-feed-across-the-flip window auto-recovers at the first
  adjusted print — do not "fix" this correct behavior).
- **Feed age**: alert at 12h weekday / 20h weekend; page at 25h (approaching the 30h bound).
  Expect routine 5–7h intraday staleness — do not alert below 12h or the channel will be ignored.
- **Divergence watcher**: |feed − spot| and |feed − TWAP| per name; alert at 50% of the
  configured thresholds (1.5% against `maxDifference` 300 / `maxPoolPriceDifference` 300).
- **Ring coverage**: alert if any pool's observation coverage < 2× `twapSeconds`.

Freeze runbook requirements (feeds into readiness §4): the exact `setLimits` five-tuple before
and after (`globalDebtLimit` ≈ current debt, daily mins 0 — verified not to brick repay/
liquidate); Friday 15:00 ET deadline; holiday/early-close calendar; per-name halt logic;
restoration conditions (first post-closure print **and** |feed−TWAP| < 2% sustained);
manual fallback owner; pre-weekend scan for loans near the liquidation threshold. Record that
deposits cannot be frozen (§1.5) and that `emergencyAdmin` authority is broader than a pause (§2.6).

---

## 6. Testing plan that is actually achievable (replaces part of readiness §10)

Readiness §10 as written is partially unachievable: **B20 calls revert on vanilla anvil/revm
forks** (§1.1, verified empirically). Split into three buckets so the checklist can be met
honestly rather than waived:

1. **Mock-tested (local):** the entire multiplier matrix (readiness §1) against a programmable
   mock B20 — dividend-sized change, forward split, reverse split, instant update, either
   ordering of multiplier vs feed prints, pool repricing before/after the print, multiplier
   bounds/zero/overflow, `multiplier()` reverting (must fail closed), borrow/health/liquidation
   through each transition; plus #446 bounds tests (fresh-but-absurd answers, decimals,
   reference-token failure).
2. **Live-simulated (stateless `eth_call`/simulation API against the live node, re-run at the
   deployment block):** transfer canary in all directions; tick-walk exit simulations per
   readiness §5 (pre/post-gap, single-name and correlated); 0x quote probes; feed round walks;
   cardinality and coverage assertions.
3. **Accepted-untested:** native-client admin behavior (burn/seizure of pool balances, client
   release semantics) — cannot be triggered or forked; covered by pilot caps, the freeze runbook,
   and issuer confirmation, and recorded as accepted risk.

---

## 7. Deploy-time smoke tests (addition to readiness §8 manifest)

After configuration, before borrows are enabled, on the live deployment:

1. `factory.getPool(token, USDC, 10)` resolves to the expected pool for all seven.
2. `oracle.getValue()` succeeds on one real position per supported pair (create one if none) and
   the implied price matches the feed within tolerance.
3. `vault.loanInfo()` round-trips on each configured pair.
4. `observationCardinality` per pool ≥ 4320 target; `sequencerUptimeFeed`, `emergencyAdmin`,
   ownership, and the full limits tuple match the manifest.
5. Simulate one borrow + repay + liquidate at minimum size per pair at pilot parameters.

---

## 8. Additions to the readiness doc's go/no-go list

Append:

- observation cardinality ≥ target on all seven pools, with the increase transaction dated
  **before** the rest of the checklist began;
- Chainlink feed-unit and Coinbase multiplier-semantics confirmations **in writing**;
- adapter (or explicitly accepted corporate-action outage) reviewed, with the §2.2 scenario table
  demonstrated in tests;
- `twapSeconds` and `maxPoolPriceDifference` values pinned, with their blackout-timing
  consequences written into the runbook;
- 0x exit quotes verified per token, or inventory-only liquidation formally accepted;
- explicit CF line (launch values + ramp conditions), not only caps;
- reserve seeding (or explicit first-loss acceptance) and `minLoanSize` derivation;
- the three-bucket testing split (§6) recorded so unachievable items are not silently waived.
