# Proposal: Coinbase tokenized equities as Revert Lend collateral (Base) — revised

**Status:** proposal, revised after two independent reviews and a third round of feedback on the
plan (2026-09-16: ownership mechanics, policy registry, cardinality, staged gates, liquidator
readiness, cross pairs; answer bounds considered and dropped). Not approved. Nothing deployed.
**Date:** 2026-09-15/16 (on-chain figures re-verified at block 51,363,041 unless noted)
**Inputs merged:** `docs/review-coinbase-equity-collateral-base.md` (independent review; where it
conflicted with the original, its evidence won) and
`docs/prompt-coinbase-equity-collateral-base-deployment-readiness.md` (go/no-go requirements).
**Implementation plan:** `docs/plan-coinbase-equity-collateral-base-deployment.md`.

Each statement below is tagged: **[verified]** measured on-chain or read from source in this tree ·
**[assumption]** believed but not proven · **[accepted risk]** known, cannot be removed, deliberately
carried · **[blocker]** must be resolved before deployment.

---

## 1. Proposal

Deploy a new Revert Lend `V3Vault` + `V3Oracle` on Base (8453) lending **USDC** against Aerodrome
Slipstream LP positions (MinUnstake factory) containing **Coinbase B20 tokenized stocks**.

- Oracle: `Mode.CHAINLINK_TWAP_VERIFY` — Chainlink `Coinbase TICKER` feeds, wrapped in a
  **multiplier-aware adapter** (no bounds, no owner), cross-checked against the pool TWAP. USDC
  reference on the raw Chainlink feed, as on every live vault.
- Launch collateral factors **55%** (AAPLc, MSFTc, GOOGLc, AMZNc, METAc) and **50%** (NVDAc, TSLAc),
  with an evidence-gated ramp to 60/55.
- Hard per-name debt caps as **concentration limits**, at **half size for the pilot**.
- A **~22h weekend liquidation blackout** is accepted by design (fail-closed oracle), with a Friday
  borrow freeze and monitoring that has been exercised through a full weekend before borrows open.
- MSTRc and SPCXc excluded. No staking (GaugeManager) at pilot. V3Utils is the only transformer at pilot.

---

## 2. Verified on-chain facts

### 2.1 Tokens — B20 standard, 8 decimals [verified]

| Token | Address | Float (09-15) | `multiplier()` |
| --- | --- | --- | --- |
| NVDAc | `0xb20000000000000000000078ee7ce2fE4908108C` | $4.21M | `1e18` |
| GOOGLc | `0xb2000000000000000000002D0BA3164cc74f58B7` | $2.08M | **`1.000377118676784179e18`** |
| AAPLc | `0xb200000000000000000000C2e324d24d7eEcd1fb` | $1.97M | `1e18` |
| METAc | `0xb2000000000000000000008bC8786B856E61707C` | $1.60M | `1e18` |
| AMZNc | `0xb200000000000000000000d9192b6B456483C2E8` | $1.41M | `1e18` |
| MSFTc | `0xB200000000000000000000Ab99cFa739E253872B` | $1.40M | `1e18` |
| TSLAc | `0xb2000000000000000000001e800a7f5189430cD0` | $1.01M | `1e18` |
| *SPCXc — excluded* | `0xb2000000000000000000007b9fcbd005511aCBd5` | $1.40M | — |
| *MSTRc — excluded* | `0xb2000000000000000000004884b426556b92883d` | $1.23M | — |

**GOOGLc has already had a cash dividend processed through the instant `updateMultiplier` path.**
Multiplier changes are routine, not tail events. Dividend-sized changes (~0.04%) are far below any
divergence tolerance; splits and emergency cuts are the cases that matter (§3.2).

Backing **[assumption, from issuer docs]**: 1:1 by shares in segregated custody at Alpaca Securities
(SEC-registered broker-dealer), bankruptcy-remote, ADGM-regulated; direct claim on the share;
dividends and voting pass through; non-US persons only, not enforced on-chain.

### 2.2 B20 execution surface [verified]

- `cast code` returns a single byte `0xef` on every token. EIP-3541 forbids deploying such code,
  so token logic lives in the **Base execution client**, not EVM bytecode. There is no bytecode to
  audit and semantics can change with a Base node release. **[accepted risk]**
- **Vanilla anvil/revm forks cannot execute B20 calls**: `transfer` reverts on a local fork while the
  identical `eth_call` on a live Base node returns `true`. This constrains testing (plan §WP3).
- Callable on the token: `multiplier()`, `policyId(bytes32 scope) → uint64`. **Reverting with their
  own selector** (native "not implemented"): `uiMultiplier()`, `newUIMultiplier()`, `effectiveAt()`,
  and `isAuthorized`/`policyAdmin`/`policyType`/`getPolicy` *on the token* — the earlier conclusion
  that "policy state is not pollable" came from probing the wrong surface and is **withdrawn**
  (2026-09-16).
- **Policy state is pollable** via the **PolicyRegistry precompile
  `0x8453000000000000000000000000000000000002`**: `isAuthorized(uint64,address)` (never reverts),
  `policyExists(uint64)`, `policyAdmin(uint64)`, `pendingPolicyAdmin(uint64)`. Verified live on
  NVDAc and MSFTc: `TRANSFER_SENDER_POLICY`, `TRANSFER_RECEIVER_POLICY`, `TRANSFER_EXECUTOR_POLICY`
  and `MINT_RECEIVER_POLICY` all resolve to **policy 5**; the two SEIZE scopes are unset.
  `policyExists(5) == true`; `isAuthorized(5, x) == true` for both pools and a fresh EOA; a
  nonexistent id also returns `true`, so **policy 5 is a blocklist** — now [verified], no longer an
  assumption. Membership cannot be enumerated, but every address the protocol depends on can be
  checked directly, block by block (plan §WP6 poller). *Role holders* (MINT/BURN/SEIZE/PAUSE/…)
  remain enumerable only from `RoleGranted` logs.
- **`policyAdmin(5) == 0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812` — a plain EOA (no code,
  unverified).** One hot key can change who may send, receive, execute transfers of, or mint every
  Coinbase stock token; `pendingPolicyAdmin(5)` is empty. **[verified; High — R16]** Coinbase must
  explain the control around this key (plan §WP1.3).
- A simulated `transfer` pool → fresh never-KYC'd address returns `true`; DEX pools hold thousands of
  shares. The transfer canary (plan §WP6) remains as the end-to-end check behind the registry poller.

### 2.3 Pools — Aerodrome Slipstream MinUnstake, all `token0 = USDC`, `tickSpacing = 10`, fee 0.05% [verified]

Factory `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` · NPM `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53`.
`factory.getPool(token, USDC, 10)` resolves correctly for all seven; the NPM `positions()` layout
decodes into the 12-field struct `V3Oracle._loadPositionState` expects.

| Pair | Pool | USDC side (review sample) | cardinality / next | worst-case ring at 2s blocks |
| --- | --- | --- | --- | --- |
| GOOGLc | `0xb1987cad1682841b4b641d50e520777ec5ab5542` | $1,102,397 | 2048 / 2048 | ~68 min |
| AAPLc | `0xa3b1e3f9747065e2073722ff4c9027d3ea4994f0` | $987,881 | 2048 / 2048 | ~68 min |
| METAc | `0xeaf57753bc382e0324a1d43f72e7027705a2273e` | $745,535 | 2048 / 2048 | ~68 min |
| NVDAc | `0x853f5f1b92b16714fe6cda67caad0856b83c7ab9` | $694,366 | 2048 / 2048 | ~68 min |
| MSFTc | `0x7103eb3c9590d1281f7dc03b2a9ee27c39df5d54` | $414,477 | **360 / 360** | **~12 min** |
| AMZNc | `0xd03bc8c7f2faedce2aac81bf0444aea08ea06e9b` | $378,554 | **360 / 360** | **~12 min** |
| TSLAc | `0x469337fdcc5e8f38e2e4b670b04f57865d13a7bb` | $351,272 | **360 / 360** | **~12 min** |

`cardinalityNext == cardinality` everywhere — nobody has requested an increase. `V3Oracle` calls
`pool.observe` unguarded (fail-closed by design), so a ring that does not reach back `twapSeconds`
would revert valuation. **Reclassified 2026-09-16: not a blocker for a 60 s TWAP.** `observe([60,0])`
needs one observation ≥ 60 s old; a 360-slot ring is exhausted only by 360 *consecutive touched
blocks*, and at 2 s/block only 30 blocks fit in 60 s. The "~12 min worst case" above is 12× the
window, and on a quiet pool the ring spans longer, not shorter. A bump to 2048 (match the other
four) is optional defence-in-depth for a future longer TWAP; 4320 was an unjustified target (~80M
gas per pool). The deployment gate is `observe([60,0])` succeeding plus measured ring span ≥ 10×
`twapSeconds`, not a cardinality number. **[verified; Low — R1]**

Measurement caveat: these tokens are also quote assets for Base memecoin pairs (BLUECHIP/NVDAc,
AAPLCAT/AAPL, ELON/TSLAc). That liquidity inflates headline TVL and is excluded above.

### 2.4 Exit liquidity — tick-walk of the live bitmap [verified, review method]

At-spot cap-sized sells show 0.1–0.6% impact — **deceptive**, nearly all liquidity sits within a few
percent of spot. After a −30% gap trade, a cap-sized liquidator exit recovers **4–12% of notional**:

| Pool | proposed cap | USDC recovered post-gap |
| --- | --- | --- |
| GOOGLc | $240,000 | ~$15,800 |
| METAc | $180,000 | ~$22,000 |
| AAPLc | $160,000 | ~$9,700 |
| NVDAc | $140,000 | ~$10,900 |
| MSFTc | $100,000 | ~$4,000 |
| AMZNc | $80,000 | ~$3,900 |
| TSLAc | $60,000 | ~$3,800 |

**In the scenario the caps were originally sized against, the pool is not the exit.** Post-gap
liquidation is viable only for desks with issuer redemption (non-US KYC) or TradFi hedging (equity
futures reopen Sunday 18:00 ET, before the feed resumes at 20:00). The liquidation penalty band is a
contract constant (2–10%, `MIN/MAX_LIQUIDATION_PENALTY_X32`); 2% does not compensate weekend
inventory risk, so expect liquidations to clear late in the band. **[accepted risk, drives §4.2–4.3]**

### 2.5 Feeds and the weekend gap [verified]

Chainlink `Coinbase TICKER` feeds on Base: 8 decimals, heartbeat 86400, deviation 0.5%.

| Feed | Address |
| --- | --- |
| Coinbase NVDA | `0x04689a41629776563E6822F76f2e57D148d28513` |
| Coinbase AAPL | `0x787f13dEa48Db0897CbCDD985de77809D837F988` |
| Coinbase GOOGL | `0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2` |
| Coinbase META | `0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D` |
| Coinbase MSFT | `0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c` |
| Coinbase AMZN | `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295` |
| Coinbase TSLA | `0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4` |
| USDC / USD (reference) | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` |
| Base sequencer uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |

NVDA aggregator `0xF72B1eB5932800F3d2a5EeC5f99e6cD586479675` round walk:

```
round 346  $218.28   Fri 2026-09-11 15:33 ET
           >>> 52.45 h, zero updates <<<
round 347  $215.70   Sun 2026-09-13 20:00 ET   (−1.18% step, no intervening discovery)
```

Weekday gap round 360→361 = 16.8h. Feed observed **7.1h stale mid-session** on Tue 09-15 (and 4.9h
on a separate sample). Multi-hour intraday staleness is routine; alert thresholds must reflect it.
A 72.5h gap was observed over Labor Day weekend.

**Round-walk over the last ≤400 rounds per feed (`script/sim/feed_roundwalk.py`, block 51372265) [verified]:**

| Feed | rounds | max closure gap (h) | max weekday gap (h) | max reopen step | live feed-vs-pool |
| --- | --- | --- | --- | --- | --- |
| AAPLc | 209 | 76.0 | 21.5 | 0.77% | 0.12% |
| MSFTc | 203 | 80.4 | 24.0 | 0.75% | 0.06% |
| GOOGLc | 180 | 81.6 | 24.0 | 0.78% | 0.12% |
| AMZNc | 221 | 75.9 | 22.3 | 1.39% | 0.26% |
| METAc | 400 | 76.8 | 18.4 | 1.02% | 0.03% |
| NVDAc | 363 | 77.9 | 17.6 | 1.18% | 0.10% |
| TSLAc | 400 | 76.0 | 18.6 | 1.01% | 0.29% |

Three-day weekends produce **76–82h** closures (the 52.45h figure is an ordinary weekend); with
`maxFeedAge` 30h that only lengthens the blackout, it does not fail open. **Weekday gaps reach exactly
24.0h** on several feeds, leaving 6h of margin under 108000s — a spurious weekday blackout is the
failure mode if that margin is ever crossed. **[review question: 30h vs 36h]** Reopen steps in the
window never exceeded 1.4%; live divergence 0.03–0.29% supports `maxDifference = 300`.

Live feed-vs-pool divergence, regular session (single sample; overnight sampling still required):
NVDAc 0.33% · METAc 0.22% · GOOGLc 0.14% · AMZNc 0.07% · AAPLc 0.05% · MSFTc 0.00%.

### 2.6 Repository state relevant to this design [verified in this tree]

- `V3Oracle` calls only `feed.decimals()` (L256) and `feed.latestRoundData()` (L419) on a feed →
  any `AggregatorV3Interface` adapter is drop-in.
- Decimal scaling for 8-dec token vs 6-dec reference is the `referenceTokenDecimals < tokenDecimals`
  branch at L355–363 — must be covered by tests.
- `setTokenConfig` **forces `Mode.CHAINLINK` for the reference token** (L261–278). Deploying from
  this tree puts USDC in CHAINLINK-only mode. Deliberate — see §3.1.
- **C4 #446 unfixed house-wide** (`_getChainlinkPriceX96` enforces only `answer <= 0` and
  staleness; no live oracle has min/max bounds). **In this vault it is covered by
  `CHAINLINK_TWAP_VERIFY`**: the Chainlink-derived price is `equityUSD / usdcUSD`, the TWAP is
  `equity/USDC` from the pool, so a garbage print on an equity feed diverges > 3% and that token
  fails closed, and a garbage print on the **USDC reference** diverges on all seven and the vault
  fails closed. Static bounds would add nothing behind a dynamic ±3% check; they were proposed and
  **dropped** (Mario, 2026-09-16). **[verified; accepted — matches live]**
- `create` / `onERC721Received` never touch the oracle → **deposits work during blackouts**.
- `V3Utils` routes every swap through `_routerSwap` (0x AllowanceHolder or Aerodrome
  UniversalRouter). The UniversalRouter is pinned to the original CL factory and **cannot reach
  MinUnstake pools**. `FlashloanLiquidator` exit legs share this dependency; inventory-take
  (`amountIn = 0`) needs no router.
- `_updateAndCheckCollateral` attributes full debt to **both** legs of a pair; any MinUnstake pair of
  two configured tokens (equity/equity) becomes borrowable collateral permissionlessly once a pool
  exists (`create` has no pool/pair allowlist; `_calculateTokenCollateralFactorX32` = `min(CF0,
  CF1)`). Caps bind both legs. **Excluding crosses is a change to the audited vault, not a frontend
  setting** — see §4.3 and R17.
- Ownership mechanics: `V3Vault`, `V3Oracle`, `V3Utils` (via `Transformer`) are **`Ownable2Step`**
  (`transferOwnership` only sets `pendingOwner`; the Safe must `acceptOwnership()`);
  `InterestRateModel` is plain `Ownable`; **`FlashloanLiquidator` has no ownership**. Every
  "transfer to multisig" in this document means transfer **and** Safe accept, verified as
  `owner() == Safe && pendingOwner() == 0`.
- V3Utils (MinUnstake) `0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD` **owner is the hot automation
  EOA `0x83681C14770b44361e21Faf91D8325423365eA5C`**; `pendingOwner() == 0` (nothing proposed).
  **[blocker — WP0]**
- Live `rlAeroUSDC` oracle conventions: `maxPoolPriceDifference` 200, `twapSeconds` 60,
  `maxDifference` 200, USDC `maxFeedAge` 86400, sequencer feed `0xBCF8…6433`.

---

## 3. Oracle design

### 3.1 Chosen configuration

```
V3Oracle(npm = MinUnstake NPM, _referenceToken = USDC, _chainlinkReferenceToken = address(0))
```

`_chainlinkReferenceToken = USDC` (hard-coding USDC = $1, no feed) was rejected: it removes depeg
detection on the unit of account. USDC is configured via `setTokenConfig` → forced `Mode.CHAINLINK`,
feed `0x7e86…bc6B` (raw, as on every live vault), `maxFeedAge` 86400 (house convention). A garbage
USDC print is caught indirectly: it moves the Chainlink-derived equity prices but not the pool
TWAPs, so all seven equities diverge and the vault fails closed (§2.6).

Equities: `Mode.CHAINLINK_TWAP_VERIFY`, feed = **`ChainlinkMultiplierFeed` adapter** (§3.2), pool =
the USDC pool in §2.3, `twapSeconds` **60**, `maxFeedAge` **108000** (30h), `maxDifference` **300**
(3%). Global `maxPoolPriceDifference` **300**.

Three independent fail-closed checks can revert valuation for an asset, and the blackout starts at
whichever fires first:

1. **Staleness** (`_getChainlinkPriceX96`): `updatedAt + maxFeedAge < now`. Fires ~30h after the last
   Friday print (Sat ~21:30 ET). Bounds: > ~24h or 16.8h weekday gaps revert spuriously; < 52.45h or
   the check is decorative.
2. **Chainlink vs TWAP divergence** (`_requireMaxDifference`, L381–383) > 3%. Observed 0.00–0.33%
   regular-session; structural floor ~0.5% (feed deviation threshold). **Do not exceed 300** — it
   doubles as the silent-multiplier-error tolerance (§3.2). Validate on overnight samples first.
3. **Spot vs derived** (`maxPoolPriceDifference`) > 3%. Fires before (2) on thin books; Sunday/Monday
   reopen wicks extend blackouts until convergence. House convention is 200; 300 chosen for these
   pools. Corollary: switching a token to CHAINLINK-only mid-crisis does **not** remove this check.

### 3.2 Multiplier-aware feed adapter — seven instances, no bounds, no owner [blocker — WP2]

Current `V3Oracle` values `rawUnits × feedPrice` and never reads `multiplier()`. Identified
**fail-open path**: an emergency `updateMultiplier` cut with transfer gating on a weekend leaves the
feed ≤30h-fresh and the pool untradeable (TWAP frozen); both checks pass while collateral is impaired,
and deposits remain open, so impaired LP can be deposited and borrowed against.

Fix — a ~20-line `AggregatorV3Interface` adapter per equity, no audited-code change, **immutable
and ownerless** (nothing to administer; replacing one is a new deploy + `setTokenConfig` from the
Safe). If Chainlink confirms token-basis units the adapter is not needed and the raw feeds are wired
directly:

```
ChainlinkMultiplierFeed.latestRoundData():
    (roundId, answer, startedAt, updatedAt, answeredInRound) = feed.latestRoundData()
    require(answer > 0)
    m = token.multiplier(); require(m > 0)             // reverts → fail-closed
    return (roundId, answer * m / 1e18, startedAt, updatedAt, answeredInRound)
decimals() = feed.decimals()
```

Answer bounds (C4 #446) were considered and dropped as redundant with the ±3% TWAP divergence check
(§2.6). Behaviour matrix — each row is a required test (WP3):

| Scenario | Adapter | Outcome |
| --- | --- | --- |
| Dividend (Δmult ≈ 0.04%) | tracks; error ≪ 3% | uninterrupted |
| 2:1 split over a weekend | stale feed $200 × mult 2 = $400 vs pool $200 | divergence reverts → bounded outage, auto-recovers at first adjusted print |
| Reverse split | symmetric | as above |
| Emergency cut + gating (weekend) | feed leg halves vs frozen pool TWAP | divergence reverts → **fail-closed; hole closed** |
| Fat-fingered multiplier | passes only if error < `maxDifference` | keep 300 |
| `multiplier()` reverts (client regression) | adapter reverts | fail-closed |
| Fresh but absurd equity answer (10× / 0.1×) | passes through | divergence > 3% → that token fails closed (#446 covered by TWAP verify) |
| Fresh but absurd USDC reference answer | n/a (raw feed) | all seven equities diverge → vault-wide fail-closed, incl. liquidations |
| USDC prints $0.98 (inside 3%) | n/a | all equity values rise ~2% in USDC terms — correct |

**Two external prerequisites are binary and gate the design [blocker — WP1]:**
1. **Written confirmation from Chainlink** that `Coinbase TICKER` feeds are **share-basis** (adjusted
   at corporate actions). If they are token-basis, the adapter double-counts and the raw config is
   correct — the answer flips the design.
2. **Written confirmation from Coinbase** that `multiplier` never scales `balanceOf`/`transfer`
   (redemption-layer only). If balances can mutate, v3 pool accounting breaks and this collateral
   type is undeployable regardless of oracle design.

### 3.3 What a blackout freezes (corrected) [verified]

| Operation | During blackout |
| --- | --- |
| Lender `withdraw` / `redeem` | works — but only while the vault holds liquid USDC; first-mover withdrawals concentrate risk on remaining lenders |
| Borrower `repay` | works |
| **Deposit collateral** (`create` / `onERC721Received`) | **works** — never touches the oracle; the Friday freeze cannot stop pre-positioning |
| `borrow` / increase debt | frozen |
| **`liquidate`** | **frozen** — the safety-critical loss |
| indebted `transform` (V3Utils etc.) | frozen |
| `loanInfo()` view | **reverts** — it values the collateral; frontends and monitors must derive debt from `loans(tokenId)` shares × `lastDebtExchangeRateX96` (found by WP3 tests) |

Fail-closed is the documented protocol policy (`docs/agents/risk-and-acceptability.md`, "Oracle-Failure
Policy"). Borrowers cannot withdraw collateral or add debt during it, so nothing can be extracted;
the residual exposure is drift-and-walk-away.

### 3.4 Rejected alternative: pool-only TWAP (`Mode.TWAP`)

Would remove the blackout (never touches Chainlink). Rejected: (1) it converts a stochastic tail
(the market must gap 34–42% over a weekend) into an adversarial one (someone must find manipulating a
$400K–$1M pool profitable, and attackers optimise); (2) it discards a multi-source feed for a single
pool as sole price authority; (3) its benefit concentrates exactly where it is least useful — after a
34% gap you would be liquidating into a book that just gapped 34% (§2.4). Retain
`CHAINLINK_TWAP_VERIFY` unless new evidence supports a better independent 24/7 reference; do not use
the 60s TWAP as routine sole oracle or automatic emergency fallback.

### 3.5 Required operational mitigation: Friday borrow freeze [blocker — WP4/WP6]

Because the buffer must absorb the whole weekend unaided, borrowing must be frozen before the blind
window. The plan specifies: the account/automation responsible; the exact `setLimits` five-tuple
before/after (`globalDebtLimit ≈ current debt`); Friday 15:00 ET deadline; holiday/early-close
calendar; per-name halt logic; monitoring of success/failure; restoration conditions (first
post-closure print **and** |feed−TWAP| < 2% sustained); manual fallback owner; pre-weekend scan of
loans near threshold. It must be **exercised through one full weekend before borrows are enabled**.
**No `emergencyAdmin` is set (`address(0)`), matching every live Revert Lend vault and oracle on
every chain — the role has never been set anywhere (zero `SetEmergencyAdmin` events house-wide)
[verified].** The role gates only `V3Vault.setLimits` and `V3Oracle.setOracleMode`; with it unset both
are **multisig-only**, so the Friday freeze and the Sunday unfreeze are each a multisig transaction.
Trade-off accepted: no hot key holds limit-rewriting authority, at the cost of needing signer quorum
every weekend — a missed Friday quorum leaves borrows open into the blind window **[accepted risk]**.

---

## 4. Risk parameters

### 4.1 Bad-debt arithmetic [verified from source]

`_calculateLiquidation` needs `fullValue ≥ 1.10 × debt` for a clean liquidation; below that
`reserveCost = 1.10 × debt − fullValue` hits reserves then lenders. **Protocol loss begins at
LTV > 90.9%.** `BORROW_SAFETY_BUFFER_X32` = 95% on the borrow path → max borrow = `0.95 × CF`.

| CF | max borrow | position fall, max-borrow → insolvency | liq-threshold → insolvency |
| --- | --- | --- | --- |
| 50% | 47.50% | 47.8% | 45.0% |
| **55%** | **52.25%** | **42.5%** | **39.5%** |
| 60% | 57.00% | 37.3% | 34.0% |
| 65% | 61.75% | 32.1% | 28.5% |

Collateral is an LP position: a wide/in-range position (value ∝ √price) needs a larger underlying
move than a narrow position already fully on the equity side (1:1). **Plan on the 1:1 figure.**
Historical adjusted close→next-open checks across the seven names found maximum negative gaps of
~10–19% **[assumption — reproduce from a documented source incl. holidays, WP7]**, well inside the
39–47% buffers. The weekly blackout is a low-probability tail and **liveness** risk, not evidence
that ordinary weekend moves create bad debt. The binding tail is issuer/wrapper failure (§3.2),
which equity gap history does not bound.

### 4.2 Collateral factors — launch one notch below the original proposal

| Asset | Launch CF | X32 | Ramp target |
| --- | --- | --- | --- |
| AAPLc, MSFTc, GOOGLc, AMZNc, METAc | **55%** | `2362232012` | 60% |
| NVDAc, TSLAc | **50%** | `2147483648` | 55% |
| USDC | 85% | `3650722201` | — |

Rationale: the binding tail is issuer/wrapper failure; liquidator compensation is a hard-coded 2–10%
against measured near-zero post-gap exit; the market is three weeks old with zero accrued reserves.
Ramp only after ≥4 clean weekends of monitoring data **and** seeded reserves.

**Excluded:** MSTRc — a leveraged bitcoin proxy; **bitcoin trades all weekend**, so its fair value
moves inside the blind window (the one name where the blackout is a live mechanism, not a tail).
SPCXc — recent IPO, no volatility history (~−30% from day-one close in six weeks).

### 4.3 Per-name debt caps — concentration limits, half-size pilot

`collateralValueLimitFactorX32` caps **debt attributed to that token** as a fraction of `lentAssets`
(`V3Vault.sol:1364–1379`); checked for **both** legs of the position; **relative, not absolute** —
tightens automatically while the vault is small. The original "≤25% of pool USDC side" rule is
cosmetic post-gap (§2.4). The numbers are retained as **single-name concentration and
TWAP-manipulation-profit limits**, and the pilot runs at **half** until reserves exist and the
readiness stressed-exit model (WP5) re-derives them.

| Token | factor (full) | debt at $2M lent | **pilot factor** | **pilot debt** | X32 (full / pilot) |
| --- | --- | --- | --- | --- | --- |
| GOOGLc | 12% | $240,000 | 6% | $120,000 | `515396075` / `257698037` |
| METAc | 9% | $180,000 | 4.5% | $90,000 | `386547056` / `193273528` |
| AAPLc | 8% | $160,000 | 4% | $80,000 | `343597383` / `171798691` |
| NVDAc | 7% | $140,000 | 3.5% | $70,000 | `300647710` / `150323855` |
| MSFTc | 5% | $100,000 | 2.5% | $50,000 | `214748364` / `107374182` |
| AMZNc | 4% | $80,000 | 2% | $40,000 | `171798691` / `85899345` |
| TSLAc | 3% | $60,000 | 1.5% | $30,000 | `128849018` / `64424509` |
| **sum** | | **$960,000** | | **$480,000** | |
| USDC | uncapped | | uncapped | | `4294967295` |

**Correction:** the per-name caps ($960K full / $480K pilot) **bind before** the $1M global debt limit
when only equity pairs are used; both ceilings exist.

**Equity/equity crosses are a protocol decision, not a frontend one.** Any MinUnstake NFT pairing
two configured equities is depositable via `create`, permissionlessly; 7 tokens → 21 pairs. They are
*strictly riskier* than equity/USDC: no USDC leg, so the √price cushion of an in-range USDC pair
disappears and both legs fall together in a correlated crash (the §4.1 1:1 figure is the *best*
case); both legs blackout together. The caps bind both legs, which is the only existing control.
**Decided (2026-09-16): accept and monitor** — no code change; nightly cross-pair scan; an
allowlist in `V3Vault` (audited-code change) is deferred to the pre-ramp review. **[accepted risk —
R17]**

### 4.4 Limits, reserves, minimum loan

- `setLimits(minLoanSize, globalLendLimit, globalDebtLimit, dailyLendIncreaseLimitMin, dailyDebtIncreaseLimitMin)`
  = `(1_000e6, 2_000_000e6, 1_000_000e6, 200_000e6, 100_000e6)` **[minLoanSize to be derived
  from measured gas + stressed exit cost; $100 was rejected — a 2% penalty on $100 is $2]**.
- Interest rate model: reuse live Aerodrome parameters `(0, 13%, 300%, 90% kink)` in Q64 **[assumption
  — confirm target utilisation]**. Reserve factor 10%, reserve protection factor 5% (house convention).
- **Reserves start at zero; first loss socialises directly to lenders.** Either seed a protocol-owned
  reserve at launch (**≥ $40–100K**, i.e. 2–5% of the lend cap) or record explicit acceptance. Future
  interest spread is not an initial reserve. **[decision for Mario]**

---

## 5. Deployment shape (detail in the plan)

New `V3Oracle`, `InterestRateModel`, `V3Vault`, `FlashloanLiquidator` (MinUnstake-bound, no owner),
seven ownerless `ChainlinkMultiplierFeed` adapters. Reuse V3Utils
`0xc3cFFd…Fe2dD` after ownership transfer **and Safe acceptance**. **No
GaugeManager at pilot** (one-shot `setGaugeManager`; MinUnstake gauge reward flow unsimulated; known
unstake OOG bistability in `docs/investigation-aerodrome-stuck-unstake-71869354.md`). No
LeverageTransformer / AutoRange / AutoExit at pilot. Neither existing Base vault is reusable
(`rlBaseUSDC` → Uniswap V3 NPM `0x03a520b3…`; `rlAeroUSDC` → original Slipstream NPM `0x82792268…`).

**Exit routing and liquidation readiness [go-live gate, Stage B]:** UniversalRouter cannot reach
MinUnstake pools, so V3Utils swaps and FlashloanLiquidator exits for B20↔USDC depend entirely on
0x. **Governance "accepting inventory-only liquidation" does not by itself create a liquidator**,
and a 0x quote today describes today's book, not the post-gap one. Borrows are enabled only when one
of the following is documented: (1) stressed-exit liquidity demonstrated by the WP5 model at a
stated recovery floor; (2) a **named, funded, B20-eligible liquidator** (non-US KYC / issuer
redemption access — an `amountIn = 0` liquidator ends up *holding* B20 LP) who has performed the
on-chain smoke-test liquidation; or (3) caps re-derived from that liquidator's capital. Degraded
transforms (no compounding) may still be accepted separately.

**Staged deployment:** Stage A deploys everything inert (`globalDebtLimit = 0`, no `setVault`) and
is gated only on pre-deployment evidence; Stage B (smoke test with a tiny debt limit, one real
liquidation, one full weekend of freeze/unfreeze, then caps) is gated on evidence from the Stage-A
deployment. Stateless `eth_call` simulation cannot chain borrow → repay → liquidate and forks cannot
run B20, so the smoke test is real transactions at `globalDebtLimit = 3 × minLoanSize`.

---

## 6. Risk register

| # | Sev | Risk | Owner | Mitigation | Status |
| --- | --- | --- | --- | --- | --- |
| R1 | Low | Observation ring (360) on three pools — cannot fail a 60 s TWAP (needs 360 consecutive touched blocks; 30 fit in 60 s) | eng | optional bump to 2048; gate = `observe([60,0])` succeeds + span ≥ 10× `twapSeconds` | reclassified 09-16 |
| R2 | High | Issuer multiplier cut + gating inside blackout fails open | eng | `ChainlinkMultiplierFeed` adapter (§3.2); tests for full matrix | **open — WP2** |
| R3 | High | Feed units / balance semantics unconfirmed — design flips if wrong | Mario | written confirmations from Chainlink + Coinbase | **open — WP1** |
| R4 | High | Post-gap exit recovers 4–12%; pool is not the exit; "accepting inventory-only" creates no liquidator | risk | CF 55/50; half-size pilot caps; **Stage-B gate: demonstrated stressed liquidity, or named funded B20-eligible liquidator who did the smoke liquidation, or capital-derived caps** | **open — WP5 / Stage B** |
| R5 | High | B20 is native-client code; issuer blocking, pause, burn, seizure possible | Mario/legal | policy state **is pollable** via registry `0x8453…0002` → poller on every protocol address (WP6); role holders from logs + legal (WP1); canary; pilot caps; **exclusion remains a possible outcome** | **open — WP1** |
| R6 | Med | `maxPoolPriceDifference` unchosen; reopen wicks extend blackouts | eng | 300, consequence in runbook; wick scenarios in tests | resolved in §3.1 |
| R7 | Med | V3Utils owned by hot key | Mario | `Ownable2Step`: hot key `transferOwnership`, **Safe `acceptOwnership`**; verify `owner()==Safe && pendingOwner()==0` before `setVault` | **open — WP0** |
| R8 | Med | No `emergencyAdmin` (matches live): freeze/unfreeze are multisig txs every weekend; missed quorum = borrows open into the blind window | Mario | weekend signing quorum + Safe tx template committed; pre-weekend near-threshold scan | **address decided; quorum open — WP6** |
| R9 | Med | Zero reserves → first loss to lenders | Mario | seed ≥$40–100K or explicit acceptance | **decision** |
| R10 | Med | Deposits cannot be frozen; pre-positioning before weekend | eng | borrowing frozen instead; documented | accepted |
| R11 | Low | C4 #446 min/max bounds absent (house-wide) | eng | covered here by `CHAINLINK_TWAP_VERIFY` divergence on equities and, indirectly, on the USDC reference; bounds dropped as redundant | **accepted — matches live** |
| R12 | Low | `minLoanSize` $100 uneconomic to liquidate | risk | ≥$1,000, derived from gas + exit | resolved in §4.4 |
| R13 | Low | Existing tests can't exercise B20 on anvil | eng | three-bucket test split (plan §WP3) | planned |
| R14 | Med | Ownership: CF/cap/config changes land with 2 Safe signatures, no timelock (older lend vaults sit behind a 48h timelock). Accepted for the pilot because the weekly freeze needs a fast `setLimits` and `emergencyAdmin` is unset | Mario | pilot caps bound the blast radius; revisit option C (timelock owner + Safe as `emergencyAdmin`) before raising caps | **decided (A) — accepted risk** |
| R15 | Low | USDC reference feed in forced `CHAINLINK` mode has no direct TWAP check; it divides every equity price | eng | a bad USDC print diverges all seven equity legs from their TWAPs → vault-wide fail-closed; no exploitable path; same as every live vault | **accepted — covered by R11 reasoning** |
| R16 | **High** | **Policy 5 admin is a plain EOA** `0xEC0F05…2812` controlling send/receive/execute/mint gating on all Coinbase stock tokens | Mario | Coinbase to explain key custody/process (WP1.3); poller on `policyAdmin`/`pendingPolicyAdmin`; pilot caps; exclusion possible | **open — WP1** |
| R17 | Med | Equity/equity crosses depositable permissionlessly; riskier than equity/USDC (no USDC leg, correlated legs, joint blackout); frontend hiding is not a control | Mario/eng | **accept + monitor** (decided 2026-09-16): caps bind both legs; nightly cross-pair scan; allowlist deferred to pre-ramp review | **accepted risk** |
| R18 | Med | Ownership mis-sequencing: `Ownable2Step` transfers left unaccepted leave the hot key as owner; `FlashloanLiquidator` has no owner | eng | scripts assert `pendingOwner`, print Safe accept batches; verify asserts `owner`+`pendingOwner`; manifest records both | planned — WP4 |

---

## 7. Assumptions, accepted risks, unresolved blockers

**Assumptions to convert to evidence:** feed share-basis units; multiplier ≠ balance scaling;
~10–19% historical max negative gap; IRM parameters fit target utilisation; who controls the
policy-admin EOA. (Policy-5 blocklist semantics: now **verified** via the registry.)

**Accepted risks (carried deliberately):** native-client B20 semantics not auditable; ~22h weekly
liquidation blackout (+ holidays); post-gap DEX exit near zero (pilot caps, 0x, or inventory-only);
deposits open during blackout; liquidation penalty band fixed at 2–10%.

**Unresolved blockers — Stage A (no deployment until closed):** V3Utils ownership transferred
**and accepted**; WP1 written confirmations (Chainlink units, Coinbase multiplier/balance semantics,
policy-admin EOA control, role enumeration, legal); WP2 adapter with independent review;
minLoan/IRM specified;
`observe([60,0])` gate green.
**Unresolved blockers — Stage B (borrows stay disabled until closed):** on-chain smoke test with one
real liquidation; liquidation-readiness route documented (stressed liquidity, named liquidator, or
capital-derived caps); stressed-exit model supporting caps; freeze/unfreeze exercised over one full
weekend on the deployed vault; weekend quorum; reserves decision; monitoring live incl. registry
poller. If any cannot be satisfied: smaller pilot, different parameters, different design, or
cancellation — **do not force a deployment recommendation.**

## 8. Questions still open for review

1. Does the adapter design (§3.2) correctly close the fail-open path, and are the two external
   confirmations sufficient to lock the units question?
2. Is 55/50 at launch with a 4-weekend ramp the right posture, or should the pilot start lower?
3. Which liquidation-readiness route is acceptable for Stage B — demonstrated stressed liquidity,
   a named funded B20-eligible liquidator, or caps sized to that liquidator's capital?
4. Is `maxPoolPriceDifference = 300` acceptable given it fires before the TWAP check on thin books?
5. ~~Equity/equity crosses~~ — decided: accept and monitor at pilot.
6. Reserve seeding amount, and who funds it.
7. Does the reviewer agree that TWAP divergence makes static answer bounds redundant on both the
   equity and USDC legs (§2.6), so C4 #446 can stay as-is here as on the live vaults?
