# Runbook: Revert Lend Coinbase Equities USDC (`rlCbEqUSDC`, Base)

**Status:** draft (plan WP6). Placeholders in `⟨angle brackets⟩` are decisions still owed by Mario
(plan §7: named liquidator, weekend signing quorum, reserve seed).
**Companion docs:** `docs/proposal-coinbase-equity-collateral-base.md` (why),
`docs/plan-coinbase-equity-collateral-base-deployment.md` (what), `script/CoinbaseEquityBaseConfig.s.sol`
(every address and parameter — the manifest of record), `deployments/base-coinbase-equity.json`.

---

## 0. The one thing to remember

The Chainlink equity feeds stop printing when US markets close. From ~30h after the last Friday print
(Saturday ~21:30 ET) until the first Sunday-evening print (~20:00 ET) the oracle **fails closed**:
no borrows, **no liquidations**, no indebted transforms. Deposits, repayments and lender withdrawals
keep working. Three-day weekends make that gap 76–82h. Nothing in this runbook removes the gap; the
runbook makes sure **no new debt is opened into it** and that everyone knows what is frozen.

---

## 1. Roles and accounts

| Role | Account | Notes |
| --- | --- | --- |
| Owner (vault, oracle, IRM) | Safe 2-of-3 `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9` | every `setLimits` is a Safe tx; no `emergencyAdmin` anywhere |
| Weekend signing quorum | ⟨signer A⟩, ⟨signer B⟩, backup ⟨signer C⟩ | on call Fri 14:00–15:30 ET and Sun 19:30–21:30 ET |
| Named liquidator | ⟨account⟩, USDC float ≥ ⟨sum of pilot caps ÷ CF⟩, B20-eligible (non-US KYC / issuer redemption) | must have executed the Stage-B smoke liquidation |
| Broadcaster (deploys only) | forge keystore `deployer` = `0x83681C14770b44361e21Faf91D8325423365eA5C` | hot auto-compound bot key; never an owner |
| Monitoring owner | ⟨person⟩ | owns the pollers in §2 and the alert routing |

Contracts (fill from `deployments/base-coinbase-equity.json` after Stage A): vault ⟨addr⟩, oracle ⟨addr⟩,
IRM ⟨addr⟩, FlashloanLiquidator ⟨addr⟩, adapters ×7 ⟨addr⟩, V3Utils `0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD`.

---

## 2. Sensors (all read-only, all against a **live** Base node — B20 code does not run on forks)

| Sensor | Script | Cadence | Alert | Page + freeze |
| --- | --- | --- | --- | --- |
| Policy registry | `script/sim/policy_registry.sh` (`WATCH_ADDRESSES="<vault> <oracle> <liquidator>"`) | 1/min | any `policyId` change, any `pendingPolicyAdmin ≠ 0`, `policyAdmin` change | any `isAuthorized == false` for a watched address |
| Role holders | `script/sim/roles_from_logs.py` with `LAST=<previous results file>` | hourly | — | any grant/revoke, especially `SEIZE_ROLE` |
| Transfer canary | `script/sim/canary.sh` (`VAULT=<vault>`) | 1/min | — | any `false`/revert |
| `multiplier()` | `cast call <token> "multiplier()(uint256)"` ×7 | 1/min | — | any change → freeze borrows; unfreeze only after the first post-change feed print and \|feed−TWAP\| < 2% |
| Feed age | `script/sim/feed_roundwalk.py` (live columns) | 5/min | 12h weekday, 20h weekend | 25h; **routine 5–7h intraday staleness is normal — never alert below 12h** |
| Divergence | same (`div%`) | 5/min | 1.5% (50% of `maxDifference`) | 3% = oracle already fail-closed |
| USDC feed age | same | 5/min | 20h | 24h (= `maxFeedAge`, vault-wide blackout) |
| Ring coverage | `script/sim/ring_coverage.sh` | hourly | oldest observation < 10 × 60s | `observe` fails |
| Debt / health | `loans(tokenId)` × `lastDebtExchangeRateX96 / Q96` per position; health from the last **good** oracle price | 1/min | position within 5% of threshold | — |
| Cross pairs | enumerate `Add` events; flag positions whose two legs are both equities | nightly | new cross-pair position | — |
| Sequencer | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | 1/min | answer = 1 | — |

**Do not use `vault.loanInfo()` for monitoring or in frontends during a blackout** — it values the
collateral and reverts for the whole gap (`V3VaultB20.t.sol::testBlackoutTable`).

---

## 3. Weekly freeze / unfreeze

### 3.1 Friday — freeze borrows (deadline **15:00 ET**, before the 16:00 close)

1. 13:30 ET — monitoring owner runs the pre-weekend scan: every position's health at the current
   price; list anything that would be liquidatable after a −20% move; ping the named liquidator with
   the list and the USDC needed.
2. 14:00 ET — one signer runs `VAULT=<vault> forge script script/CoinbaseEquityBorrowLimits.s.sol:FreezeBorrows --rpc-url $BASE_RPC_URL`
   (simulation only; prints the Safe tx). Target tuple: `setLimits(minLoanSize, globalLendLimit, currentDebt, 0, 0)`.
3. Propose in the Safe with the printed `to`/`data`; second signer confirms; execute **before 15:00 ET**.
4. Verify: `cast call <vault> "globalDebtLimit()(uint256)"` equals the printed `currentDebt`.
5. Post in ⟨channel⟩: "rlCbEqUSDC frozen at debt X, tx Y".

Known nuance: the frozen limit caps **total** debt, so repayments during the weekend can be
re-borrowed up to that total. Net exposure cannot grow; do not describe the freeze as "no borrowing".

**Missed quorum by 15:00 ET:** borrows stay open into the blind window. Fallback: ⟨signer C⟩;
escalate at 15:30; the pre-weekend scan becomes the only defence — repeat it at 16:30 ET and alert the
liquidator to anything near threshold.

### 3.2 Sunday — unfreeze (earliest ~20:30 ET)

Restore only when **all** hold:
- every equity feed has printed after the 20:00 ET reopen (`feed_roundwalk.py` ages all < 1h);
- \|feed − TWAP\| < 2% on all seven for 15 sustained minutes (reopen wicks extend blackouts);
- `multiplier()` unchanged on all seven since Friday (or the multiplier procedure in §5.2 completed);
- canary and policy registry green.

Then `UnfreezeBorrows` (same flow) → `setLimits(1_000e6, 2_000_000e6, 1_000_000e6, 200_000e6, 100_000e6)`;
verify `globalDebtLimit()`; post in ⟨channel⟩.

### 3.3 Calendar (NYSE; verify each January against the official list)

Freeze on the **last trading day before** each closure at 15:00 ET; early closes (13:00 ET) move the
deadline to **12:00 ET**. Remaining 2026: Thu Nov 26 Thanksgiving (Fri Nov 27 early close), Fri Dec 25
Christmas (Thu Dec 24 early close). 2027: Jan 1, Jan 18, Feb 15, Mar 26 (Good Friday — feeds stop but
Base does not), May 31, Jun 18 (Juneteenth observed), Jul 5 (Independence Day observed), Sep 6, Nov 25
(Nov 26 early close), Dec 24 (Christmas observed; Dec 23 early close). Every holiday closure produces a
70–90h gap; the oracle is fail-closed for all of it.

---

## 4. Blackout behaviour (what to tell users)

| Operation | During blackout |
| --- | --- |
| Deposit collateral (`create`) | works |
| Borrow / increase debt | **frozen** (oracle revert) |
| Repay | works |
| Liquidate | **frozen** — the safety-critical loss; nobody can be liquidated |
| Indebted transform (V3Utils) | frozen |
| Lender `withdraw`/`redeem` | works while the vault holds liquid USDC (first-mover risk) |
| `loanInfo()` | **reverts** — see §2 |

---

## 5. Incidents

### 5.1 Feed failure (age > 25h on a weekday, or feed reverts)
Freeze borrows (§3.1 flow, any day). Do **not** switch a token to `Mode.CHAINLINK` or `TWAP` as a
fallback — `maxPoolPriceDifference` still applies and the TWAP-only mode is rejected by design
(proposal §3.4). Wait for Chainlink; if > 48h on a weekday, escalate to Chainlink and consider
`setTokenConfig` to a replacement feed via the Safe (48h+ decision, not an emergency lever).

### 5.2 Corporate action / `multiplier()` change
Expected outcome: the adapter changes the token price instantly; the feed adjusts per share at its
next print; between the two the oracle diverges > 3% and **fails closed for that name only** — this is
correct. Steps: freeze borrows; confirm the new multiplier against the issuer notice; wait for the
first adjusted print; confirm \|feed−TWAP\| < 2%; unfreeze. **Never** "fix" the divergence by widening
`maxDifference`.

### 5.3 Issuer policy change (registry poller or canary trips)
Freeze borrows immediately. Identify which address lost authorization. If a **pool or the vault** is
blocked: collateral is trapped — liquidations cannot move tokens; treat as an exclusion event for that
name: set its CF to 0 via the Safe (`setTokenConfig(token, 0, 0)`) so no new debt can be opened against
it, contact Coinbase, and prepare a lender communication. If a `SEIZE_ROLE` is granted to anyone:
same response for all seven pending explanation.

### 5.4 Failed or late liquidation
Named liquidator did not act within 30 minutes of a position becoming liquidatable (outside blackout):
⟨backup liquidator / team account⟩ executes `FlashloanLiquidator` or a direct `liquidate` with
`amountIn = 0` (inventory-take; the exit for B20 is 0x or issuer redemption, never the UniversalRouter).
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

With `globalDebtLimit = 0` after the smoke test, run one full weekend: Friday freeze (a no-op tuple
change, still signed and executed), all sensors live, Sunday unfreeze back to `0`. Attach the Safe tx
hashes, the sensor logs and the sign-off of both weekend signers to the plan's go/no-go before
opening borrows.
