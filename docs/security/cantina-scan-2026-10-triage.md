# Cantina Apex scan (October 2026) – triage

Scan: `revert-finance/lend`, branch `aero`, commit `268b48450f12712cb0222523912ab4f7f3e09b88` (44 findings: 2 High,
39 Medium, 1 Low, 2 Informational).

Status note: the pull requests referenced below have all merged into `aero`: #65 (df8116a), #64 (7785e4e),
#67 (0ea357a), #68 (32ff6da) and, for the vault bytecode size, #69 (64c6619). Entries marked *fixed in*,
*by design since* or *mitigated since* describe code that is now on `aero`: LEND-1, LEND-12 and LEND-44 no longer
reproduce there, and the compound-only reward policy that LEND-51, LEND-23 and LEND-37 rely on is in place.

## How the findings were triaged

Everything on `aero` outside `src/GaugeManager.sol` and its interfaces is byte-identical to the Base Aerodrome
deployment baseline (`aerodrome-slipstream`, `ff9e75afbdd9af847e5a5c026466e179027da490`), and most of it also exists
in the mainnet/Arbitrum deployments built from `main`. The triage rule applied here:

- Code that is **new on `aero`** (gauge reward accounting, reward-compound transforms, the deferred-reward escrow) is
  fixed when the finding describes a real defect.
- Code that is **already live and operating as designed** is not changed for a finding that describes a known
  trade-off, a trusted-role assumption (protocol owner, Revert operator bot, owner-approved delegate) or an
  operational/configuration matter. Those findings are acknowledged below with the reason, so the decision is
  recorded next to the code.
- Findings describing a real loss path are fixed even when live, because new deployments are built from `aero`
  (the live vaults are immutable and keep their behaviour).

Columns: *Live Base* = present in the Base deployment baseline; *Live main* = present on `main`.

## A. Vault transform authorization and position replacement

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-1 | High | yes | yes | **Fixed in #65** (df8116a): transform approvals are tagged with a per-token epoch that `remove` increments, so delegates of an earlier deposit expire. |
| LEND-12 | High | yes | yes | **Fixed in #65** (df8116a): a replacement NFT is accepted only if the active transformer announced that exact token with `expectReplacement`, once. |
| LEND-44 | Med | yes | yes | **Fixed in #65** (df8116a; combination of LEND-1 and LEND-12; both preconditions are gone). |
| LEND-46 | Med | yes | yes | Acknowledged. Raw ERC-721 deposits taking the owner from callback data is a documented, accepted trust assumption (`NOTE FOR AUDITS` in `onERC721Received`): an ERC-721 operator approved for the token can already move it anywhere, so registering it under its own identity is within the authority the NFT owner granted. |
| LEND-5 | Med | yes | yes | Acknowledged. Vault and transformers are deployed per position manager by the protocol owner; a mismatched pair is an administrative error. A preflight check in the deployment scripts is the right place for a guard, not vault bytecode. |
| LEND-7 | Med | yes | yes | Acknowledged. Transform mode applies the direct health check without the borrow buffer by design; the replacement stays collateralized above the liquidation threshold and the behaviour is documented in the vault. |
| LEND-27 | Med | yes | yes | Acknowledged. Same design decision as LEND-7. |
| LEND-59 | Low | yes | yes | Acknowledged. AutoRange plans are keyed by token id; after a V3Utils range change the owner reconfigures the new token. No loss. |

## B. Automation fee and reward accounting (`AutoExit`, `AutoRangeAndCompound`, `Automator`)

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-18 | Med | yes | yes | Acknowledged. Automation treats what `collect` returns as its reward base; principal left in `tokensOwed` after a partial decrease is the owner's to collect first. Bounded by the configured reward. Documented guidance: collect before relying on automation. |
| LEND-8 | Med | yes | yes | Acknowledged. Same reasoning as LEND-18 (zero-liquidity range plan after a full decrease). |
| LEND-11 | Med | yes | yes | Acknowledged. Same reasoning; the mainnet `AutoCompound` has identical behaviour. |
| LEND-13 | Med | yes | yes | Acknowledged. Same reasoning. |
| LEND-20 | Med | yes | n/a* | Acknowledged. `maxRewardX64` caps range-execution rewards; auto-compounding uses the contract-wide `totalRewardX64`, exactly as the separate mainnet `AutoCompound` contract does. Documented. |
| LEND-25 | Med | yes | yes | Acknowledged. The add minima are dust gates on collected fees; the reward is charged on what is actually compounded. |
| LEND-9 | Med | yes | yes | **Fixed in #71**: the auto-compound swap now passes the position's configured `token0SlippageX64` / `token1SlippageX64` tolerance (applied to the pre-swap spot price) as the minimum output, so an execution below it reverts with `SlippageError`; the TWAP check keeps skipping the swap when the price deviates. Initially acknowledged as the production design, fixed on request. |
| LEND-30 | Med | yes | yes | Acknowledged. Route calldata is supplied by the operator, a trusted protocol role; the owner-set minimum bounds the outcome. |

\* on `main` auto-compounding is a separate contract without a per-position cap.

## C. Aero gauge rewards and deferred-reward escrow (new on `aero`)

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-4 | Med | no | no | **Fixed in #68** (32ff6da): the plain operator wrappers `executeWithVault` / `autoCompoundWithVault` refuse to unstake a staked position inside the gauge's early-unstake penalty window, matching the guard of the reward-aware wrappers. |
| LEND-2 | Med | no | no | **Fixed in #67** (0ea357a): reward swaps record the actual input consumed, so a partial fill returns the unconsumed receipt tokens to the position owner instead of leaving them as sweepable manager balance. |
| LEND-51 | Med | no | no | **By design since #64** (7785e4e); superseded by its compound-only policy: every transform compounds staked rewards (best-effort, no minimum); `autoCompoundRewardMin` only tunes the operator's explicit entrypoint, and the generic vault call is available to the owner or an owner-approved delegate only. |
| LEND-23 | Med | no | no | **By design since #64** (7785e4e): rewards are always compounded; the `autoCompound` flag governs fee auto-compounding, not gauge rewards. Documented. |
| LEND-31 | Med | no | no | Acknowledged. The gauge manager's compound fee (at most 2 %, owner can only lower it) is a separate protocol fee on reward compounding; `maxRewardX64` applies to range-operation fees. Documented. |
| LEND-52 | Med | no | no | Acknowledged. Upstream `claimEmissions` mints the account bucket together with the position reward in one call, so position claims cannot be decoupled from bucket capacity by the manager. Principal exits are unaffected; claims resume when emission headroom grows. Documented in the runbook. |
| LEND-37 | Med | no | no | **Mitigated since #64** (7785e4e): the strict reward-compound transform reverting on an unfundable bucket is the keeper's explicit choice; plain `transform` compounds best-effort and always proceeds to the unstake. |
| LEND-43 | Med | no | no | Acknowledged. The deferred bucket cannot drift with the pinned CLGauge (only the manager can move it); since #63 the exit path records the withdrawal delta without a strict pre-check, so exits stay live. |
| LEND-54 | Med | no | no | Acknowledged. A deferred liability stays recorded against the gauge that created it; funding depends on that gauge's upstream emission capacity. A migration would need upstream support. Documented. |

## D. Leverage transformer: delegate-chosen recipients and swap calldata

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-33 | Med | yes | yes | Acknowledged. `approveTransform` deliberately grants a delegate full transform authority over that token (protocol primer); the owner chooses delegates. |
| LEND-35 | Med | yes | yes | Acknowledged. Same reasoning. |
| LEND-49 | Med | yes | yes | Acknowledged. Swap calldata is supplied by the owner or their delegate for their own position; `amountOutMin` is the owner's protection. |

## E. Swapper and router accounting

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-14 | Med | yes | yes | Acknowledged. Universal Router payloads built by Revert include the input sweep; the payload is user-supplied data. |

## F. Oracle (`V3Oracle`, `ChainlinkFeedCombinator`)

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-3 | Med | yes | yes | Acknowledged. Round-completeness fields are not relied upon since v1; OCR feeds publish complete rounds and TWAP verification bounds any deviation. |
| LEND-48 | Med | yes | yes | Acknowledged. A token changing `decimals()` in place is a token-governance event that requires reconfiguration; operational runbook item. |
| LEND-39 | Med | yes | yes | Acknowledged. Same: a decimal-changing feed migration requires an oracle reconfiguration; the TWAP check fails closed meanwhile. |
| LEND-38 | Med | yes | yes | Acknowledged. The derived-root truncation misvalues only extreme low-unit-price pairs by tens of basis points; candidate precision improvement for a future oracle release, not a change to live behaviour. |
| LEND-41 | Med | yes | yes | Acknowledged. `maxFeedAge` and the sequencer grace period are deliberate configuration; the TWAP check bounds deviation. |
| LEND-26 | Med | yes | yes | Acknowledged. TWAP-only mode is an explicit configuration; the live Arbitrum configuration uses it only for the reference token. |

## G. Vault economics and limits

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-6 | Med | yes | yes | Acknowledged. A full-loss liquidation leaving a zero lender index is the terminal insolvency state of a vault; such a vault is wound down and redeployed. Recorded in the risk docs. |
| LEND-58 | Med | yes | yes | Acknowledged. The per-token exposure cap is an origination check by design. |
| LEND-10 | Med | yes | no | Acknowledged. Daily limits are rate throttles; the same-day haircut interaction cannot move funds. |
| LEND-21 | Med | yes | no | Acknowledged. Same; the lend-side rescale is a consistency improvement candidate. |
| LEND-17 | Med | yes | yes | Acknowledged. Lazy accrual from the live balance is the v1 design; the demonstrated gain (about $10.86 over a year with capital locked) is far below its cost. |
| LEND-22 | Med | yes | yes | Acknowledged. `maxPoolPriceDifference` is a deliberate tolerance between oracle and pool price. |
| LEND-36 | Info | yes | no | Acknowledged. The scan itself found no incremental borrowing capacity. |

## H. Flashloan liquidator

| ID | Sev | Live Base | Live main | Disposition |
|---|---|---|---|---|
| LEND-29 | Med | yes | yes | Acknowledged. The helper pays its token balances to the current liquidator; a residual balance from a liquidator-supplied route is an edge case that affects liquidators only. |

## I. Repository hygiene

| ID | Sev | Disposition |
|---|---|---|
| LEND-55 | Info | **Action outside the code**: revoke and rotate the two Alchemy keys found in Git history and check the projects' usage. Fork tests already read RPC URLs from environment variables. Rewriting history is an organisational decision and was not done. |

## Summary

| Disposition | Findings |
|---|---|
| Fixed in #65 (df8116a) | LEND-1, LEND-12, LEND-44 |
| Fixed in #67 (0ea357a) / #68 (32ff6da) | LEND-2, LEND-4 |
| By design or mitigated since #64 (7785e4e) | LEND-51, LEND-23, LEND-37 |
| Fixed in #71 | LEND-9 |
| Operational action | LEND-55 |
| Acknowledged | the remaining 34 |

The referenced PRs merged into `aero` on 2026-10-18/19 in the order #65, #64, #67, #68, this document, then #69,
which keeps `V3Vault` under the EIP-170 size limit and adds `script/check-sizes.sh`; run that guard before merging
any vault change.
