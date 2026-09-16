# Prompt: turn the Coinbase equity collateral proposal into a deployment-ready plan

Use `docs/proposal-coinbase-equity-collateral-base.md` as the source proposal. Review the
current repository code and fresh Base onchain state, then produce a revised, deployment-ready
plan. Preserve the original proposal's useful analysis, but correct unsupported statements,
resolve the blockers below, and turn every operational assumption into an explicit owner,
transaction, alert, test, or runbook.

Do not deploy or broadcast anything while completing this work. Do not treat a successful build
or the existing generic Aerodrome tests as sufficient evidence. All addresses, balances, oracle
answers, pool observations, token policies, roles, multipliers, and ownership must be rechecked at
the intended deployment block.

## Required changes and investigations

### 1. Define and test B20 multiplier-aware valuation

The current `V3Oracle` prices raw ERC-20 balances and does not read the B20 multiplier. Confirm in
writing, from authoritative Coinbase and Chainlink documentation or direct confirmation, exactly
what one unit of each Chainlink `Coinbase TICKER` feed represents:

- one underlying/displayed share;
- one raw B20 token unit; or
- a Coinbase instrument unit that already incorporates the multiplier.

Do not assume these units from ticker names or approximate price agreement.

GOOGLc has already used `updateMultiplier` for an announced cash dividend and had a multiplier of
approximately `1.000377118676784179` during the 2026-09-15 review. Recheck this transaction and
all seven current multipliers. Also recheck which multiplier interfaces are actually live. During
the review, the legacy `multiplier()` and instant `updateMultiplier` behavior existed, while the
documented scheduled ERC-8056 reads (`uiMultiplier`, `newUIMultiplier`, and `effectiveAt`) reverted.

If the Chainlink feed is per displayed share, specify and implement the raw-unit conversion, which
is expected to be equivalent to:

```text
raw B20 unit price = Chainlink share price * multiplier / 1e18
```

Confirm the direction and rounding independently. Add tests covering:

- a small dividend multiplier change below the oracle divergence threshold;
- a forward split;
- a reverse split;
- an instant multiplier update;
- a scheduled update if that interface becomes live;
- multiplier and Chainlink updates occurring in either order;
- the pool repricing before and after the feed update;
- multiplier bounds, zero/invalid results, and arithmetic overflow;
- borrowing, health checks, and liquidation throughout each transition.

If multiplier-aware valuation is not implemented, describe corporate-action oracle outages as an
explicitly accepted limitation, demonstrate why no valuation error can pass the verifier at a
dangerous size, and provide the monitoring and governance response. Do not merely state that the
multiplier is cosmetic: raw AMM accounting and economic/share-unit valuation are different
questions.

### 2. Address B20 policy, pause, block, burn, and seizure risk

Replace the statement that no policy is active. At review time, all relevant scopes used mutable
policy ID 5, which was permissive but operated as a blocklist. Enumerate for every token:

- the policy ID and type for every scope;
- policy administrators;
- default admin and all operational roles;
- pause and unpause roles and current pause state;
- burn, `burnBlocked`, seizure, mint, metadata, and operator capabilities;
- whether the pool, NPM, vault, GaugeManager, transformers, liquidators, and recipients can each
  be blocked independently.

Analyze the specific case where an Aerodrome pool is blocked and its B20 balance is burned or
seized while Slipstream still records liquidity for existing positions. Determine whether oracle
valuation remains theoretical, whether collection or liquidation reverts, and whether any
recovery mechanism exists.

Obtain legal and issuer confirmation about treatment of protocol and pool addresses. State what
protection, notice, recovery, or redemption rights actually exist. Monitoring alone is not a
mitigation for an instant administrative action. If this risk cannot be contractually or
technically bounded, present exclusion of B20 collateral as a possible outcome rather than
assuming deployment must proceed.

### 3. Complete the Chainlink answer-bounds fix

Resolve C4 #446 before deployment. The current oracle only rejects stale and non-positive answers.
Do not rely on the aggregators' exposed maximum values if they are economically meaningless.

Define protocol-level minimum and maximum prices for each asset, their units, who may update them,
and the emergency procedure when a bound is reached. Test fresh but absurd answers, decimals,
reference-token failures, and arithmetic limits. Obtain review of the exact post-audit code change.

Explain accurately that, in `CHAINLINK_TWAP_VERIFY`, an absurd answer normally causes a
Chainlink/TWAP mismatch and a fail-closed outage. The bounds issue is defense in depth and a
liveness safeguard unless an incorrect answer can also pass the verifier.

### 4. Keep the dual-source oracle, but make blackout operations concrete

Retain `CHAINLINK_TWAP_VERIFY` unless new evidence supports a better independent 24/7 reference.
Do not use the 60-second Aerodrome TWAP as the routine sole oracle or automatic emergency fallback.

Calibrate the weekend risk using the actual solvency math:

- at 60% collateral factor, a freshly maximum-borrowed position needs about a 37.3% collateral-
  value decline to enter bad debt;
- at 55%, it needs about a 42.5% decline;
- a position already at the liquidation threshold needs approximately 34% and 39.5%, respectively;
- an in-range LP generally requires a larger underlying-stock move than a position already fully
  converted to the equity side.

Historical adjusted close-to-next-session-open checks performed during review found maximum
negative gaps of approximately 10-19% across the seven names, not 34-42.5%. Reproduce the analysis
from a documented data source and include holidays and exceptional closures. Treat the weekly
blackout as a low-probability tail and liveness risk, not as evidence that ordinary weekend moves
create bad debt.

Nevertheless, specify the complete borrow-freeze process because an opportunistic borrower should
not be allowed to enter immediately before a known blind window. The plan must name:

- the account or automation responsible;
- the exact `setLimits` calls and the full five-value parameter tuple before and after the freeze;
- the time zone, Friday deadline, holiday and early-close calendar, and stock-specific halt logic;
- monitoring for success, failure, missed transactions, and unexpected feed staleness;
- the restoration conditions after feeds resume and Chainlink/TWAP agreement is healthy;
- a manual fallback and who may invoke it;
- pre-weekend identification of loans already near the liquidation threshold.

Document the authority granted to `emergencyAdmin`: it can change all vault limits, not only pause
borrowing. Do not give an ordinary keeper an unconstrained hot key without an explicitly accepted
security model.

### 5. Replace reserve-ratio caps with executable-liquidation analysis

Do not size debt caps as a fixed percentage of the pool's displayed USDC balance. Debt, liquidation
value, and stock sale input are different amounts. After a stock gap, arbitrage may already have
removed USDC, and concentrated-liquidity ranges can make reserve-ratio approximations misleading.

For each pool, simulate or quote liquidation and exit using current tick-level liquidity and range
distribution. Cover at least:

- the proposed maximum debt plus the applicable liquidation incentive;
- 10%, 20%, 30%, and 40% underlying-price shocks;
- positions that are in range, narrowly ranged, and fully on the equity side;
- pre-gap and post-arbitrage pool states;
- single-name and correlated seven-name liquidation;
- available external arbitrage/liquidator capital;
- transaction costs, MinUnstake behavior, swap fees, and realistic slippage limits.

Derive initial per-name caps from the amount a liquidator can actually exit at an adequate profit,
not from headline TVL. Provide the model, inputs, reproducible commands, and sensitivity analysis.
Use materially smaller pilot caps if the evidence is incomplete.

Correct the existing arithmetic statement: the proposed per-name caps total `$960,000`, so their
sum binds before the `$1,000,000` global debt limit when only these equity pairs are used.

### 6. Correct lender-liquidity and reserve assumptions

State that lender withdrawals during an oracle blackout do not call the oracle but succeed only
while the vault holds sufficient liquid USDC. Analyze first-mover withdrawal behavior and the
concentration left with remaining lenders.

Specify:

- the interest-rate model and all immutable parameters;
- reserve factor and reserve-protection factor;
- initial utilization targets;
- whether protocol-owned reserves, insurance, junior capital, or another backstop are funded at
  launch;
- how a new vault with little or no accrued reserves absorbs its first loss.

Do not describe future interest spread as an initial reserve.

### 7. Reconsider the minimum loan size

Justify `minLoanSize` using measured Base gas, MinUnstake handling, liquidation calls, and realistic
equity disposal. A `$100` loan can provide only a very small liquidation reward and permits severe
loan fragmentation. Select a minimum for which liquidation remains profitable under stressed gas
and exit conditions, or add a credible batching mechanism.

### 8. Provide an exact deployment and ownership manifest

The revised plan must list every deployed or reused contract, constructor argument, immutable,
initialization call, owner, pending owner, emergency admin, operator, and required acceptance step.
Include at least:

- `V3Oracle`, including `twapSeconds`, per-token `maxDifference`, global
  `maxPoolPriceDifference`, sequencer feed, feed age, reference token, and answer bounds;
- `InterestRateModel`;
- `V3Vault`, limits, collateral factors, per-token caps, reserve settings, and roles;
- `GaugeManager`, or an explicit decision not to support staking;
- gauge mappings for all supported pools if staking is enabled;
- `V3Utils` and every enabled transformer;
- multisig ownership transfers and acceptance transactions;
- monitoring, keeper, and emergency accounts.

The existing MinUnstake `V3Utils` at `0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD`
was owned by the high-frequency automation EOA
`0x83681C14770b44361e21Faf91D8325423365eA5C` during review. Transfer it to the approved multisig
before wiring the vault, verify ownership onchain, call `V3Utils.setVault(newVault)`, and authorize
it in the vault. Do not proceed while the repository's documented hot-key ownership open item
remains unresolved.

If using `GaugeManager`, verify its vault binding before the vault's one-time
`setGaugeManager` call. Confirm every supported gauge belongs to the correct MinUnstake factory and
document the effect of the minimum stake time on reward forfeiture during liquidation.

### 9. Complete legal and product review

Attach or cite authoritative evidence for backing, custody segregation, bankruptcy treatment,
redemption, dividends, voting, corporate actions, market hours, eligible holders, and geographic
restrictions. Obtain legal review of permissionless lending and liquidation involving tokenized
securities, including lenders, borrowers, liquidators, protocol governance, frontends, and
automation operators.

Do not treat the absence of onchain KYC enforcement as evidence that offchain restrictions do not
apply.

### 10. Add deployment-specific verification

Create a fork-based test and simulation suite against the intended Base block. It must cover:

- all seven tokens, feeds, pools, and gauges;
- live B20 policies, roles, pause state, and multiplier behavior;
- 60-second observations and sufficient history;
- spot-vs-derived and Chainlink-vs-TWAP checks;
- feed staleness through weekday, weekend, holiday, and delayed-resumption scenarios;
- borrow freeze and restoration;
- corporate actions and multiplier transitions;
- blocked pool, blocked vault, blocked liquidator, burn, and seizure scenarios;
- liquidation while unstaked and staked;
- stressed liquidator profitability and exit slippage;
- lender withdrawals at increasing utilization;
- configuration and ownership assertions after deployment.

Simulate the exact deployment and configuration transactions from the intended multisig. Produce a
machine-readable manifest and verify every postcondition. Require an independent reviewer to check
the final commit, manifest, simulation output, and intended deployment bytecode.

## Required output

Produce the following artifacts without broadcasting transactions:

1. A corrected proposal that clearly distinguishes verified facts, assumptions, accepted risks,
   and unresolved blockers.
2. A severity-ranked risk register with an owner and mitigation for every item.
3. A parameter table containing exact onchain values and the evidence supporting each value.
4. An ordered deployment transaction manifest, including ownership transfers and role setup.
5. A monitoring and incident-response runbook covering weekends, holidays, feed failures,
   corporate actions, issuer policy changes, and failed liquidations.
6. Reproducible fork tests and liquidation/exit simulations.
7. A final go/no-go checklist whose items can be independently verified onchain.

## Minimum go-live conditions

Recommend **no deployment** until all of the following are true:

- Chainlink feed units relative to B20 raw and scaled units are authoritatively established;
- multiplier behavior is handled in code or explicitly bounded with a tested incident process;
- C4 #446 is fixed and reviewed;
- issuer blocking, burning, and seizure consequences are understood and formally accepted;
- caps are supported by stressed executable-liquidity results;
- the weekend/holiday automation and manual fallback have been exercised;
- interest, reserves, minimum loan size, and initial loss absorption are specified;
- all ownership and emergency roles are on approved accounts, including MinUnstake `V3Utils`;
- the exact deployment has passed fork simulation and independent review;
- legal approval has been recorded.

If any condition cannot be satisfied, recommend a smaller guarded pilot, different parameters, a
different oracle or collateral design, or cancellation. Do not force a deployment recommendation.
