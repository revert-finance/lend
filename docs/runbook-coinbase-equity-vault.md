# Runbook: Revert Lend Coinbase Equities USDC (`rlCbEqUSDC`, Base)

**Status:** draft (plan WP6). Placeholders in `⟨angle brackets⟩` are decisions still owed before
Stage B (plan §7: incident signers, monitoring owner, named liquidator and reserve seed).
**Companion docs:** `docs/proposal-coinbase-equity-collateral-base.md` (why),
`docs/plan-coinbase-equity-collateral-base-deployment.md` (what), `script/CoinbaseEquityBaseConfig.s.sol`
(every address and parameter — the manifest of record), `deployments/base-coinbase-equity.json`.

---

## 0. The one thing to remember

The vault has two feed-age windows. After an equity price is **2h old**, new debt and other
risk-increasing collateral operations stop automatically, while liquidation continues using the
same price and TWAP checks until the print is **30h old**. After 30h, valuation fails closed and
liquidation also stops. Deposits, repayments and lender withdrawals keep working. No weekly Safe
transaction is required; `globalDebtLimit = 0` remains the manual emergency backstop.

---

## 1. Roles and accounts

| Role | Account | Notes |
| --- | --- | --- |
| Owner (vault, oracle, IRM) | Safe 2-of-3 `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9` | emergency `setLimits` and oracle reconfiguration require the Safe; no `emergencyAdmin` anywhere |
| Incident signing quorum | ⟨signer A⟩, ⟨signer B⟩, backup ⟨signer C⟩ | needed only for manual emergency actions, not ordinary weekends |
| Named liquidator | ⟨account⟩, USDC float ≥ ⟨sum of pilot caps ÷ CF⟩, B20-eligible (non-US KYC / issuer redemption) | must have executed the Stage-B smoke liquidation |
| Broadcaster (deploys only) | forge keystore `deployer` = `0x83681C14770b44361e21Faf91D8325423365eA5C` | hot auto-compound bot key; never an owner |
| Monitoring owner | ⟨person⟩ | owns the pollers in §2 and the alert routing |

Contracts (fill from `deployments/base-coinbase-equity.json` after Stage A): vault ⟨addr⟩, oracle ⟨addr⟩,
IRM ⟨addr⟩, FlashloanLiquidator ⟨addr⟩, adapters ×7 ⟨addr⟩, V3Utils `0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD`.

---

## 2. Sensors (all read-only, all against a **live** Base node — B20 code does not run on forks)

| Sensor | Script | Cadence | Alert | Protocol response |
| --- | --- | --- | --- | --- |
| Policy registry | `script/sim/policy_registry.sh` (`WATCH_ADDRESSES="<vault> <oracle> <liquidator>"`) | 1/min | any `policyId` change, any `pendingPolicyAdmin ≠ 0`, `policyAdmin` change | any `isAuthorized == false` for a watched address |
| Role holders | `script/sim/roles_from_logs.py` with `LAST=<previous results file>` | hourly | — | any grant/revoke, especially `SEIZE_ROLE` |
| Transfer canary | `script/sim/canary.sh` (`VAULT=<vault>`) | 1/min | — | any `false`/revert |
| `multiplier()` | `cast call <token> "multiplier()(uint256)"` ×7 | 1/min | — | any change → freeze borrows; unfreeze only after the first post-change feed print and \|feed−TWAP\| < 2% |
| Feed age | `script/sim/feed_roundwalk.py` (live columns) | 5/min | 90m; page at 12h on a weekday | at 2h the vault automatically enters liquidation-only mode; at 30h liquidation also stops |
| Divergence | same (`div%`) | 5/min | 1.5% (50% of `maxDifference`) | 3% = oracle already fail-closed |
| USDC feed age | same | 5/min | 20h | 24h (= `maxFeedAge`, vault-wide blackout) |
| Ring coverage | `script/sim/ring_coverage.sh` | hourly | oldest observation < 10 × 60s | `observe` fails |
| Debt / health | `loans(tokenId)` × `lastDebtExchangeRateX96 / Q96` per position; health from the last **good** oracle price | 1/min | position within 5% of threshold | — |
| Cross pairs | enumerate `Add` events; flag positions whose two legs are both equities | nightly | new cross-pair position | — |
| Sequencer | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | 1/min | answer = 1 | — |

**Do not use `vault.loanInfo()` for monitoring or in frontends after the 2h operational limit** — it
uses the strict valuation path. Use `vault.loanInfoForLiquidation()` for liquidation monitoring
during the 2–30h window; it uses the same valuation path as `liquidate()`.

---

## 3. Automatic feed-age circuit breaker

### 3.1 Normal transition into a closure

1. Before a known closure, monitoring runs the pre-closure scan: every position's health at the current
   price; list anything that would be liquidatable after a −20% move; ping the named liquidator with
   the list and the USDC needed.
2. No Safe transaction is scheduled. For each LP, normal valuation automatically rejects once either
   equity feed is more than 2h old. Borrow, indebted transform, staking and collateral removal then
   revert; repayments and deposits continue.
3. Confirm the first `ChainlinkPriceError` from an operational-path canary after the 2h boundary and
   confirm `getValueForLiquidation()` still succeeds. Page immediately if those results are reversed.
4. At 30h, confirm liquidation valuation also rejects. This is the known liquidation blackout.

### 3.2 Automatic recovery

Normal operations recover without an admin transaction when **all** hold:
- every equity feed has printed after the 20:00 ET reopen (`feed_roundwalk.py` ages all < 1h);
- \|feed − TWAP\| < 2% on all seven for 15 sustained minutes (reopen wicks extend blackouts);
- `multiplier()` unchanged on all seven since the last good feed print (or the multiplier procedure
  in §5.2 completed);
- canary and policy registry green.

If an emergency Safe freeze was applied, recovery of the oracle does **not** restore the debt limit.
Only then run `UnfreezeBorrows`, after the conditions above are satisfied.

### 3.3 Manual emergency freeze

For a policy change, transfer-canary failure, multiplier incident, or unexpected oracle behavior, run
`FreezeBorrows`. It prints a Safe transaction setting
`setLimits(minLoanSize, globalLendLimit, 0, 0, 0)`. A zero debt ceiling is a strict freeze: repayments
cannot reopen borrow capacity. Existing debt is not modified. Restore with `UnfreezeBorrows` only
after the incident-specific checks pass.

### 3.4 Calendar (NYSE; verify each January against the official list)

The calendar drives monitoring and liquidator staffing, not an admin transaction. Remaining 2026:
Thu Nov 26 Thanksgiving (Fri Nov 27 early close), Fri Dec 25
Christmas (Thu Dec 24 early close). 2027: Jan 1, Jan 18, Feb 15, Mar 26 (Good Friday — feeds stop but
Base does not), May 31, Jun 18 (Juneteenth observed), Jul 5 (Independence Day observed), Sep 6, Nov 25
(Nov 26 early close), Dec 24 (Christmas observed; Dec 23 early close). Holiday closures produce
70–90h gaps: normal operations stop after 2h and liquidation stops after 30h.

---

## 4. Blackout behaviour (what to tell users)

| Operation | Feed age 2–30h | Feed age >30h |
| --- | --- | --- |
| Deposit collateral (`create`) | works | works |
| Borrow / increase debt | **frozen** | **frozen** |
| Repay | works | works |
| Liquidate | **works**, subject to TWAP/divergence checks | **frozen** |
| Indebted transform / collateral removal | frozen | frozen |
| Lender `withdraw`/`redeem` | works while liquid USDC remains | works while liquid USDC remains |
| `loanInfo()` | reverts; `loanInfoForLiquidation()` works | both revert |

---

## 5. Incidents

### 5.1 Feed failure (age > 12h on a weekday, or feed reverts)
Borrowing has already stopped automatically. Consider the manual zero-limit freeze (§3.3) if the
failure appears systemic. Do **not** switch a token to `Mode.CHAINLINK` or `TWAP` as a
fallback — `maxPoolPriceDifference` still applies and the TWAP-only mode is rejected by design
(proposal §3.4). Wait for Chainlink; if > 48h on a weekday, escalate to Chainlink and consider
`setTokenConfig` to a replacement feed via the Safe (48h+ decision, not an emergency lever).
For every equity reconfiguration, use the eight-argument overload and state both `7200` and
`108000`; never use the seven-argument overload for an equity, even though it now preserves an
already-distinct liquidation window.

### 5.2 Corporate action / `multiplier()` change
Expected outcome: the adapter changes the token price instantly; the feed adjusts per share at its
next print; between the two the oracle diverges > 3% and **fails closed for that name only** — this is
correct. Steps: apply the emergency freeze; confirm the new multiplier against the issuer notice;
wait for the first adjusted print; confirm \|feed−TWAP\| < 2%; unfreeze. **Never** "fix" the divergence by widening
`maxDifference`.

### 5.3 Issuer policy change (registry poller or canary trips)
Freeze borrows immediately. Identify which address lost authorization. If a **pool or the vault** is
blocked: collateral is trapped — liquidations cannot move tokens; treat as an exclusion event for that
name: set its CF to 0 via the Safe (`setTokenConfig(token, 0, 0)`) so no new debt can be opened against
it, contact Coinbase, and prepare a lender communication. If a `SEIZE_ROLE` is granted to anyone:
same response for all seven pending explanation.

### 5.4 Failed or late liquidation
Named liquidator did not act within 30 minutes of a position becoming liquidatable (outside blackout):
⟨backup liquidator / team account⟩ executes `FlashloanLiquidator`, which uses
`loanInfoForLiquidation()` and therefore remains available in the 2–30h window. Setting the helper's
`amount0In`/`amount1In` to zero skips those swaps and only works when the collected USDC can repay
the flash loan; any residual B20 is inventory. The capital-backed fallback is a direct
`vault.liquidate()` call: the caller supplies and approves USDC and receives the collected assets
(that vault call has no `amountIn` parameter). The exit for B20 is 0x or issuer redemption, never
the UniversalRouter. The named and backup liquidators must drill both routes after the 2h cutoff.
Record the delay; if repeated, cut caps.

### 5.5 Lender run during blackout
Nothing to do on-chain: withdrawals are honoured while liquidity lasts; borrowers cannot extract
value. Communicate the blackout end time. Consider lowering `globalLendLimit` after the event.

### 5.6 Bad debt realised
`Liquidate` event with `reserveCost > 0`. Reserves start at ⟨seed amount / zero⟩; loss beyond
reserves socialises to lenders. Post-mortem: which gap, which position, which cap; reduce CF/caps
before the next weekend.

---

## 6. Pre-launch dress rehearsal (plan §4 step 7)

With `globalDebtLimit = 0` after the smoke test, run one full weekend with all sensors live. Record
the automatic transition from normal to liquidation-only at 2h, the liquidation blackout at 30h,
and automatic recovery after fresh prints. Separately exercise one emergency freeze/unfreeze Safe
cycle; it is an incident drill, not a weekly procedure. Attach logs and transaction hashes to the
plan's go/no-go before opening borrows.
