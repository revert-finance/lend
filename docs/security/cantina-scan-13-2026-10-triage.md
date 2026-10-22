# Cantina Apex scan #13 (October 2026) – triage

Scan: `revert-finance/lend`, branch `aero`, commit `faf837017529d066e38bf6379031086e63175ea9` (36 findings: 32 Medium,
4 Low), created 2026-10-21. It follows the first scan of `aero` (commit `268b484`, 44 findings) whose triage is in
[cantina-scan-2026-10-triage.md](cantina-scan-2026-10-triage.md); several findings below restate findings of that
scan and are dispositioned the same way, with a cross-reference.

## How the findings were triaged

Same rule as for the first scan. Every finding was checked against the code that is live:

- *Live Base* = the Base Aerodrome deployment baseline (`aerodrome-slipstream`, `ff9e75afbdd9af847e5a5c026466e179027da490`);
- *Live main* = `main` (mainnet / Arbitrum deployments).

Code that is identical to a live deployment and operating as designed is **acknowledged** with the reason, not changed
for the scanner: the live vaults are immutable and changing audited behaviour to satisfy a finding adds risk without
benefit. Code that is **new on `aero`** (gauge reward swaps, operator-managed staking, compound modes, the swap
minimum-output helper of #71) is fixed when the finding describes a real defect. `n/a` means the code path does not
exist in that deployment.

The scan found no High or Critical issue. Two findings describe real defects in new `aero` code and are fixed in #74
(LEND-77, LEND-128). The rest is live behaviour, a trusted-role assumption, a documented design decision or rounding
dust; two of those (LEND-105 / LEND-111, below) deserve a product decision for the next Base release and are marked
as such.

## A. Vault economics and limits (`V3Vault`, `VaultLib`)

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-81 | Med | yes | yes | Acknowledged. `_repay` is unchanged from the live vaults: an asset amount that still converts to exactly the open debt shares is pulled in full and all shares are burned, so at most one share's worth of assets (one base unit in the PoC) stays with the vault as reserves. Exact repayment is available by shares (`isShare = true`). |
| LEND-92 | Low | yes | yes | Acknowledged. The same conversion remainder for a partial asset-mode repayment (at most one share's worth); the PoC shows no loss beyond rounding dust. |
| LEND-76 | Med | yes | yes | Acknowledged. The per-token collateral-value limit is an origination check (first scan, LEND-58): it bounds new debt against the lender base when debt is created and is not an invariant under lender withdrawals. |
| LEND-78 | Med | yes | no | Acknowledged. The transaction-local fresh-share counter is a flash-deposit guard for the lender base and is aggregate by design. The sequence needs older shares at least as large as the fresh deposit, i.e. real capital that the same account could already withdraw right after borrowing (LEND-76), so it adds at most that amount once more to a throttle. Per-owner provenance tracking is not worth the vault bytecode. |
| LEND-110 | Med | yes | no | Acknowledged. Same mechanism as LEND-78 applied to the daily debt cap, a rate throttle (first scan, LEND-10). |
| LEND-93 | Med | yes | no | Acknowledged. `VaultLib.handleReserveLiquidation` keeps the live vault's order (haircut rescale of the daily headroom, then the liquidator payment is credited). Daily limits are rate throttles and the interaction cannot move funds (first scan, LEND-10 and LEND-21). |
| LEND-80 | Med | yes | yes | Acknowledged. The interest model prices utilization from cash and debt and lenders earn the reserve-adjusted supply rate on their claim; the small difference accrues to reserves. v1 design, identical in all live vaults. |
| LEND-99 | Med | yes | yes | Acknowledged. Lazy accrual from the live balance is the v1 design (first scan, LEND-17). The donation only reprices the interval since the last accrual, and every deposit, withdrawal, borrow, repayment or liquidation by anyone ends that interval, so in an active vault the gain is minutes of interest; the PoC's year-long idle interval is not a realistic state. |
| LEND-103 | Med | yes | yes | Acknowledged. Same as LEND-99. |
| LEND-86 | Med | yes | yes | Acknowledged, operational. A rate-curve change is a governance action; the vault must be checkpointed in the same batch right before `InterestRateModel.setValues`, e.g. with `withdrawReserves(0, owner)` (owner-only, accrues interest, transfers nothing). Runbook item for every deployment. |
| LEND-90 | Med | yes | yes | Acknowledged. A lender index worn down to a few units by repeated socialized losses is the terminal insolvency state of a vault, which is wound down and redeployed (first scan, LEND-6). |
| LEND-126 | Med | yes | yes | Acknowledged. Transforms apply the direct health check without the borrow buffer by design (first scan, LEND-7 and LEND-27); `aero` adds the buffer only when a transform newly enters staked custody, because staking switches to the fee-less valuation. |

## B. Oracle (`V3Oracle`)

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-82 | Med | yes | yes | Acknowledged. TWAP-only mode is an explicit configuration and the live configurations use it only for the reference token (first scan, LEND-26); the sequencer check belongs to the Chainlink path by design. |
| LEND-95 | Med | yes | yes | Acknowledged. The reference-pool price conversion truncates only for raw prices below 2^-96, which no real token pair reaches, and fails closed when it does (first scan, LEND-38 class). Candidate precision improvement for a future oracle release. |
| LEND-98 | Med | yes | yes | Acknowledged. `startedAt` is the standard Chainlink field for the last status transition; the uptime feed's `updatedAt` is not a heartbeat. Price feeds keep their own `maxFeedAge` and the TWAP verification bounds a stale price (first scan, LEND-41). |

## C. Automators (`AutoExit`, `AutoRangeAndCompound` reward base and plans)

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-104 | Med | yes | yes | Acknowledged. Automation treats what `collect` returns as its reward base; principal left in `tokensOwed` after a partial decrease is the owner's to collect first (first scan, LEND-18 class). |
| LEND-112 | Med | yes | yes | Acknowledged. Same reasoning for the fee auto-compound (first scan, LEND-11; the mainnet `AutoCompound` behaves identically). |
| LEND-73 | Med | yes | yes | Acknowledged. Plans are keyed by token id. After a transfer nothing executes until the new owner approves the automator at the position manager, and the new owner can replace or clear the plan at any time. The operator is a trusted protocol role that charges its standard reward, not the plan's cap. |
| LEND-116 | Med | yes | yes | Acknowledged. Same for `AutoExit` plans. |
| LEND-127 | Med | yes | yes | Acknowledged. `setApprovalForAll` is the documented requirement for AutoRange; a token-specific approval cannot survive the mint of a replacement. The frontend requests the operator approval. |

## D. Transformers (`V3Utils`, `LeverageTransformer`) and the Slipstream position manager

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-130 | Med | yes | yes | Acknowledged. The residual allowance is granted to the configured position manager only, which spends it solely inside its own mint / increase calls for the caller, and it is reset before every use. |
| LEND-96 | Med | yes | yes | Acknowledged. Needs a third party to pre-fund the position manager with ETH worth the whole WETH leg; that party loses the ETH and gains nothing, the user's WETH stays in V3Utils. No incentive. |
| LEND-122 | Med | yes | yes | Acknowledged. A fake "vault" caller can only spend balances already sitting in `LeverageTransformer`; the contract holds none between operations. |
| LEND-105 | Med | yes | n/a | Acknowledged (live), **product decision**. The Slipstream position manager calls `refundETH()` at the end of `mint` and `increaseLiquidity`, and `V3Utils.receive()` accepts ETH only from WETH9, so one wei forced into the position manager makes every V3Utils mint / increase revert until anyone calls `refundETH()` on the position manager (the caller keeps the wei). Identical to the live Base V3Utils; griefing only, the operation reverts atomically and no funds are at risk. Candidate for the next Base V3Utils release: accept ETH from the position manager in `receive()` (an owner sweep for stray ETH would complete it). |
| LEND-111 | Low | yes | n/a | Acknowledged (live), same decision as LEND-105 for `Automator.receive()` (AutoRangeAndCompound's fee compounds and replacements through the Slipstream position manager). |

## E. V3Utils range replacement and AutoRange token-scoped state

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-85 | Med | yes | yes | Acknowledged. V3Utils is a generic transformer: a range change through it is a new position for every automator and the owner configures the replacement again (first scan, LEND-59; the frontend offers this). The replacement's compound mode is the `Advanced` default, which any owner may select for their own position at any time: "the mode is the frontend's pricing, not an on-chain guarantee" (`docs/aero-migration.md`, "Compound modes and fees"). A migration hook between V3Utils and AutoRange would couple two independent transformers for a bounded fee effect. |
| LEND-88 | Med | yes | yes | Acknowledged. Same as LEND-85. |
| LEND-91 | Med | yes | yes | Acknowledged. Same as LEND-85. |
| LEND-94 | Med | yes | yes | Acknowledged. Same as LEND-85. |

## F. Operator-managed staking (new on `aero`)

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-87 | Med | no | no | Acknowledged. `autoCompoundForStakeChange` is reachable only as the payload of a vault transform started by the loan owner or an owner-approved transform delegate, for a position whose owner opted into operator-managed staking. It compounds the owner's own collected fees at the position's mode rate, a strict subset of what such a delegate may already do with the position (first scan, LEND-33). |
| LEND-114 | Med | no | no | Acknowledged, by design. Fees the gauge realizes on deposit or withdrawal belong to the position owner and are forwarded to the owner. Staked Slipstream liquidity earns no LP fees (the pool routes them to the gauge), so the collect at withdrawal returns only pre-stake fees already paid out at deposit, nothing in practice; the PoC models the delta with a fixture knob. |
| LEND-120 | Med | no | no | Acknowledged, by design. The cooldown counts the operator's custody decisions, not the physical unstake / restake that every transform of a staked position performs (each compound would otherwise reset it); the gauge penalty window is the hard guard and is enforced on every unstake. Clarified in `docs/aero-migration.md`. |
| LEND-117 | Low | no | no | Acknowledged, by design. Consent is scoped to a position in a vault. A direct rerange outside the vault produces a new token whose vault relationship starts fresh with its deposit (transform approvals expire the same way since the LEND-1 fix); the owner opts in again for the new deposit. |
| LEND-106 | Low | yes | yes | Acknowledged. The live vaults migrate the caller's approval only; a replacement the owner starts directly keeps AutoRange's copied configuration but needs a new `approveTransform` for the replacement token. Candidate improvement for a future vault release (size permitting), not a change to live behaviour. |

## G. GaugeManager reward swaps and the swap minimum-output helper (new on `aero`)

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-77 | Med | no | no | **Fixed in #74.** The two-hop route bound now uses the full-precision spot quote that the per-hop bounds already use (`Swapper._calculateAmountOutMin` with zero tolerance, the `OracleLibrary.getQuoteAtTick` arithmetic), so it holds at every valid price. Before, a second hop below 2^-96 floored the route quote to zero, which dropped the route bound and let both per-hop tolerances compound (about 3.94 % instead of 2 %), or divided by zero in the other direction. Regression tests in `test/unit/GaugeManager.t.sol`. |
| LEND-128 | Med | no | no | **Fixed in #74** for the reward-compound swaps: GaugeManager requires at least one output unit whenever the spot quote is positive, for the per-hop and the route bound, so a fee-bearing pool cannot consume the input for nothing (`_positiveQuoteMinimum`; tests in `test/unit/GaugeManager.t.sol`). The fee auto-compound swap in `AutoRangeAndCompound` keeps the plain floor of the shared helper: its amount is chosen by the operator per execution out of the position's collected fees (never a one-unit quote), the tolerance is the owner's own setting, and the contract sits at its bytecode size guard (24,291 of 24,320 bytes; the guard in the shared helper costs 18 bytes there). |

## Summary

| Disposition | Findings |
|---|---|
| Fixed in #74 | LEND-77, LEND-128 |
| Acknowledged, live behaviour with a product decision for the next Base release | LEND-105, LEND-111 |
| Acknowledged, operational runbook item | LEND-86 |
| Acknowledged | the remaining 31 |
