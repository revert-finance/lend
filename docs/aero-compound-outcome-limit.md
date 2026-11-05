# Alternative to #114: bound compound leftovers

This PR is an alternative to the carry-forward ledger in #114, based directly on
`aero` at `1c0be248dc2b2c55a4c191612a289118cd5b170c`. Do not merge both without
reconciling their different policies. Nothing has been deployed by this PR.

## Rule and tradeoff

With `force = false`, a compound reverts with `ExcessiveCompoundLeftover()` if
any checked token has more than `max(1, floor(available / 200))` smallest units
left over. This permits at most 0.5%, inclusive, or one smallest unit for rounding.
The one-unit exception can exceed 0.5% for tiny amounts. An NPM operation that
would mint zero liquidity can still revert: this does not override upstream rules.

For fee compounding, `available` is each token's amount **after the swap minus
the actual protocol fee**, and `used` is the amount accepted by the NPM. For
reward compounding, check both (a) unconsumed receipt tokens and (b) each resulting
pool token, again after its actual protocol fee. Fees continue to be charged only
on the amount added; existing fee arithmetic and owner payouts are unchanged.

These are separate token/stage bounds, not an oracle-valued percentage of the
original earnings or a minimum-liquidity/value guarantee. Sequential reward
stages can each leave up to their allowance. Swap fees and execution losses are
still governed by the existing swap protections; this check does not strengthen
those bounds. A small balance in one token may fail even when its dollar value
is negligible relative to the other token. The policy is deliberately simple,
conservative, independent of token decimals, and requires no new oracle.

`force = true` bypasses only these leftover checks. It does not bypass caller
permissions, owner consent, cooldowns, penalty windows, compound minimums,
slippage, deadlines, or TWAP checks. Existing authorized operators can force
compounds; existing owner/vault authorities retain their own entrypoints. No new
caller gains access. Bots should pass `false` by default, and must not silently
retry every rejection with `true`, which would make the policy ineffective.

A requested fee-compound swap now reverts on a failed TWAP check in either mode,
instead of silently continuing without the swap. No requested swap means no
additional TWAP requirement. Existing owner-configured swap limits still apply.

Fee callback errors are surfaced by the vault as its existing `TransformFailed()`
error; direct calls and pre-callback reward failures expose the original error.

A rejected strict compound rolls back collection, fees, liquidity changes, and
custody changes. It can be retried with better sizing or later conditions. A
forced compound pays leftovers through the existing owner payout path; for
Poolside this is the holder. No ledger is added, and these tokens are not reused
by later compounds. Their claim/exit handling remains the holder's existing
behavior. #113's exit-conversion changes are a separate, complementary proposal.

## Entry points and ABI migration

`AutoCompoundParams` is unchanged. Update bot/client ABIs and calldata:

- `autoCompound((uint256,bool,uint256,uint256),bool force)`
- `autoCompoundForStakeChange((uint256,bool,uint256,uint256),bool force)`
- `autoCompoundWithVault((uint256,bool,uint256,uint256),address,bool force)`
- `IVault.RewardCompoundParams` appends `bool force` after `stakeTarget`:
  `(uint256 minAeroReward,uint256 aeroSplitBps,uint256 deadline,uint8 stakeTarget,bool force)`.
  This changes the selectors of `transformWithRewardCompound`,
  `autoCompoundWithVaultAndRewardCompound`, and `executeWithVaultAndRewardCompound`.
  The combined compound wrapper forwards the same flag to reward and fee stages,
  including custody-switch callbacks. Range execution uses it only for the
  preceding reward compound; principal from a range change is not capped.
- `GaugeManager.compoundRewards(uint256,uint256,uint256,uint256,bool force)`
- `GaugeManager.unstakeIfStakedCompounding(uint256,bool,uint256,uint256,uint256,bool force)`

Explicit reward-compound transforms are strict: a failed reward or fee stage
reverts the whole operation. **Ordinary `vault.transform` retains its existing
best-effort reward pre-compound.** That self-call uses `force = false`; if it
fails, the vault can continue its existing withdrawal/reward-payout or deferral
path. This preserves principal operations, but does not promise every ordinary
transform compounded rewards. `autoCompoundWithVault(..., true)` overrides only
its fee callback, not that best-effort reward stage. Use the explicit combined
wrapper when requiring atomic reward and fee compounding with the chosen flag.
Direct unstaking/withdrawal and later deferred reward claims are not compounds
and are not blocked by this cap. Fees realized separately during gauge deposits
retain their existing owner payout behavior.

## Deployment and size

The threshold is fixed; no new storage or configuration transaction is required.
Immutable deployed contracts do not acquire these changes. If selected, deploy a
coherently bound fresh vault, GaugeManager, and AutoRange (and consumers such as
Poolside that bind that stack); update bot ABIs before enabling execution. The
existing full deployment script performs the bindings, with borrowing disabled.
Do not combine new selectors with an old deployed vault or automator.

To keep GaugeManager deployable, the existing `AeroRewardDelivery.validate`
function is linked as an external library rather than inlined. Its body is
unchanged. Foundry deploys/links it automatically, just as it already does
VaultLib. Preserve both library addresses for verification. The verification
script expects the ten protocol contracts plus these two libraries; combined with
#113, it also includes the linked `PoolsidePositionDeployer` (13 creations total).

Optimized runtime sizes with Solidity 0.8.24, via-IR, optimizer runs 25:

| Contract | Bytes | Spare under 24,576 |
| --- | ---: | ---: |
| AutoRangeAndCompound | 24,543 | 33 |
| GaugeManager | 23,914 | 662 |
| V3Vault | 22,544 | 2,032 |

AutoRange has very little spare space. Tests assert the actual deployed runtime
limits; future changes must repeat this check.

## Comparison

| | This PR | #114 carry-forward |
| --- | --- | --- |
| Poorly utilized compound | Reverts by default; authorized explicit override | Succeeds and records leftovers |
| Leftover custody | Existing payout to owner/holder | Per-position ledger for reuse |
| Later reuse | None | Included in later compounds |
| New accounting state | None | Balances, reserves, and lifecycle handling |
| ABI migration | Required | Different integration changes; see #114 |
| Main operational cost | More retries; explicit force may be needed | More custody/accounting code to review |

Existing tests use `force = true` where preserving the old leftover behavior is
intentional. New tests exercise strict rejection, rounding and percentage
boundaries, protocol-fee exclusion, owner payout, rollback, force authorization,
TWAP/slippage enforcement, fee/reward wrappers and custody transitions.

## Validation results

- `forge test --match-path 'test/{unit,integration/aerodrome,poolside,fork}/**' --code-size-limit 1000000`:
  **422 passed, 0 failed** across 35 suites, with `BASE_RPC_URL` set to an archive RPC.
  The raised limit is for large test harnesses; separate assertions check actual
  production runtime code against EIP-170.
- Covers the full fresh-deployment/binding rehearsal, all three reward routes,
  root settlement, gauge discovery, and Poolside lifecycle behavior on pinned
  Base forks. The new WETH/USDC tests use the real pool/NPM for ratio drift and
  liquidity addition, with fee collection mocked to isolate the outcome check.
  Forced leftovers include native ETH from the existing WETH-unwrapping payout.
- Local regressions cover simulated post-swap impact/ratio changes, strict TWAP
  failure, both token limits, rounding, receipt leftovers, actual protocol fees,
  rollback, authorization, staking switches and pre-range reward compounding.
- `git diff --check` and verification-script syntax parsing passed.
- Legacy Ethereum/Uniswap fork tests were updated for the ABI but not run because
  their configured `ANKR_API_KEY` is unavailable. No live transactions were sent.
