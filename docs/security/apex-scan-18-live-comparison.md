# Apex scan 18: comparison with the older live Aerodrome stack

User-selected baseline: Base vault `0x1ef7c181188687e20a9750714f1b9de6f70f17c0`, not the replacement deployed October 27. Compared on October 28, 2026. Source under repair: `b16c84df570fe5956e5749e94b8572e3195fa5e9` (`aero`), isolated branch `codex/apex-latest-fixes`.

[Completed scan](https://ai.cantina.xyz/revert-finance/workspace/LEND/scan/18), ID `f54a4f0c-19b7-4c96-bddb-a5fb16d76eb0`. All 28 returned findings are accounted for below, including duplicates. Apex classifications and remediation state have not been changed.

## Baseline evidence

Retrieved verified source bundles from BaseScan for the [vault](https://basescan.org/address/0x1ef7c181188687e20a9750714f1b9de6f70f17c0#code), [oracle](https://basescan.org/address/0x82722327e45e86a0f2107746f423f612139b0952#code), [GaugeManager](https://basescan.org/address/0xc171f8c6ed8253151de50ab839e3a468028113f2#code), [AutoRange](https://basescan.org/address/0xeb6127dcfb1e4107dc1f3111151f779920c213dd#code), [AutoExit](https://basescan.org/address/0xc35e20379c3267b5f63e569c25959031ac588203#code), and [NPM](https://basescan.org/address/0x827922686190790b37229fd06084350E74485b72#code). The vault's NPM, oracle and GaugeManager bindings were checked with on-chain reads (near Base block 53208017) and match these source addresses. Deployment addresses/roles also match the repository's legacy baseline and bindings manifests. Extracted source hashes are in `apex-scan-18-baseline-evidence.json`.

“Already present” means the verified deployed implementation contains the reported behavior. It does not mean that an exploit transaction has occurred, that every prerequisite currently holds, or that the issue is harmless. Inherited findings remain intentionally unfixed under the user's scope restriction.

## Decisions

| Finding | Apex classification | Comparison and action |
| --- | --- | --- |
| [LEND-134](https://ai.cantina.xyz/revert-finance/finding/LEND-134) | duplicate | Skip: legacy Automator computes fees as collected minus only the current decrease; prior owed principal is included. |
| [LEND-135](https://ai.cantina.xyz/revert-finance/finding/LEND-135) | duplicate | Skip: legacy AutoRange positionConfigs are keyed by token ID and survive ownership transfers. |
| [LEND-136](https://ai.cantina.xyz/revert-finance/finding/LEND-136) | duplicate | Skip: same legacy Automator fee-base behavior as LEND-134. |
| [LEND-138](https://ai.cantina.xyz/revert-finance/finding/LEND-138) | partially_valid | Skip: legacy V3Vault uses checkpoint-dependent simple interest on its current debt index. |
| [LEND-141](https://ai.cantina.xyz/revert-finance/finding/LEND-141) | duplicate | Skip: legacy V3Oracle checks grace and feed age without requiring a post-restart observation. |
| [LEND-142](https://ai.cantina.xyz/revert-finance/finding/LEND-142) | valid | No Base change: unchanged ChainlinkFeedCombinator helper is not configured in either Base stack. This report is scoped to the selected Base deployment; it does not claim this issue exists on Base. |
| [LEND-143](https://ai.cantina.xyz/revert-finance/finding/LEND-143) | valid | Fix: new root-settlement deployment preflight; the older manager has no root-delivery validator. |
| [LEND-145](https://ai.cantina.xyz/revert-finance/finding/LEND-145) | duplicate | Skip: legacy AutoRange also treats previously owed principal as collected compound fees. |
| [LEND-146](https://ai.cantina.xyz/revert-finance/finding/LEND-146) | duplicate | Skip: same legacy principal/fee attribution as LEND-145. |
| [LEND-147](https://ai.cantina.xyz/revert-finance/finding/LEND-147) | duplicate | Skip: legacy V3Vault also converts liquidation value into liquidity at the current pool price. |
| [LEND-148](https://ai.cantina.xyz/revert-finance/finding/LEND-148) | duplicate | Skip: legacy AutoRange/Swapper allow a zero output minimum after rounding. |
| [LEND-150](https://ai.cantina.xyz/revert-finance/finding/LEND-150) | duplicate | Skip: same legacy zero-minimum swap behavior as LEND-148. |
| [LEND-151](https://ai.cantina.xyz/revert-finance/finding/LEND-151) | duplicate | Skip: same legacy zero-minimum swap behavior as LEND-148. |
| [LEND-152](https://ai.cantina.xyz/revert-finance/finding/LEND-152) | duplicate | Skip: same legacy zero-minimum swap behavior as LEND-148. |
| [LEND-153](https://ai.cantina.xyz/revert-finance/finding/LEND-153) | valid | Fix: CompoundMode and GaugeManager.compoundModeSource are new; legacy AutoRange has no per-token fee tier. |
| [LEND-154](https://ai.cantina.xyz/revert-finance/finding/LEND-154) | duplicate | Skip: legacy Swapper accepts output equal to its rounded zero minimum. |
| [LEND-155](https://ai.cantina.xyz/revert-finance/finding/LEND-155) | valid | Skip: legacy verified LeverageTransformer has no payable receiver, and legacy NPM increaseLiquidity also calls refundETH(). |
| [LEND-156](https://ai.cantina.xyz/revert-finance/finding/LEND-156) | valid | Fix: stakingConsent is new; validate the current economic owner before copying it. |
| [LEND-157](https://ai.cantina.xyz/revert-finance/finding/LEND-157) | duplicate | Skip: legacy reserve socialization uses the same rounded total-lent denominator and proportional Q96 haircut. |
| [LEND-159](https://ai.cantina.xyz/revert-finance/finding/LEND-159) | partially_valid | Skip: legacy V3Oracle also rejects only sequencerAnswer == 1. |
| [LEND-161](https://ai.cantina.xyz/revert-finance/finding/LEND-161) | duplicate | Skip: same legacy reserve-haircut truncation as LEND-157. |
| [LEND-162](https://ai.cantina.xyz/revert-finance/finding/LEND-162) | valid | Skip: legacy GaugeManager has the same raw-zero quote/minimum route behavior. |
| [LEND-163](https://ai.cantina.xyz/revert-finance/finding/LEND-163) | partially_valid | Fix: new operator staking cooldown needs vault-authenticated migration for V3Utils and other replacement transformers. |
| [LEND-166](https://ai.cantina.xyz/revert-finance/finding/LEND-166) | partially_valid | Fix: new cooldown must remain on the reusable original NFT as well as its replacement. |
| [LEND-168](https://ai.cantina.xyz/revert-finance/finding/LEND-168) | duplicate | Skip: legacy V3Vault interest update also derives utilization from its current cash balance. |
| [LEND-170](https://ai.cantina.xyz/revert-finance/finding/LEND-170) | partially_valid | Skip: selected legacy Base feed ages and verification settings are carried forward; this is the same stale-anchor risk. |
| [LEND-172](https://ai.cantina.xyz/revert-finance/finding/LEND-172) | duplicate | Skip: legacy AutoRange also checks configured minima against collected balances before adding liquidity. |
| [LEND-173](https://ai.cantina.xyz/revert-finance/finding/LEND-173) | valid | Fix the newly introduced plain-path best-effort compound ordering. Require entry readiness as well as existing callback readiness. The older strict reward-aware path already compounds before its trigger; leave that existing path unchanged. |

## Implementation notes

- Plain AutoRange vault execution checks readiness before any reward swap, and keeps its existing post-compound readiness and slippage checks. The precheck uses the existing linked VaultLib to keep runtime size bounded.
- Range replacement copies the fee tier and deletes the original tier, expires an intervening owner's staking consent, and retains timing on both reusable NFTs.
- V3Vault's authenticated replacement-receipt hook uses its dedicated, owner-configured `stakingPolicy` binding to migrate cooldown state. DeployAeroProtocol binds AutoRange and checks the result. The binding is set once before enabling operator staking and cannot be cleared or changed, independently of the optional GaugeManager `compoundModeSource`. Manager-only deployments must bind the policy on their separately prepared vault. Policy contracts must implement IStakingPolicy. The hook does not copy unrelated transform approvals or grant fresh consent to V3Utils replacements.
- Root-mode manager preflight executes the reward-delivery validator in a separate helper, created outside broadcast, so Foundry does not evaluate address(this) in the script context.
- These are source changes. Existing immutable deployments are not patched by editing this branch; no deployment, activation, Apex feedback, or Fix Review has been performed.

## Validation

- `forge build --root fixtures/upstream-gauge`: pinned upstream fixture build passed (Solc 0.7.6).
- `forge test --match-path 'test/{unit,integration/aerodrome}/**' -vv`: **289 passed, 0 failed, 0 skipped**, across 31 suites. Includes the new fee-mode, stale-consent, reusable-NFT cooldown, V3Utils replacement, migration-authentication and reward-swap trigger regressions. V3Utils cooldown coverage includes an initially absent fee source and one disabled after the operator's first decision; binding tests cover owner-only setup, invalid addresses and attempts to clear or replace the policy.
- `forge script test/unit/DeployAeroGaugeManager.t.sol:RootGaugeScriptRegression --sig 'runRoot()' -vv`: passed in actual Forge script context, without broadcast.
- `bash script/check-sizes.sh`: both clean-build modes passed the existing **24,320-byte** guard (EIP-170 limit 24,576).

| Contract | Source-only runtime | Full-build runtime |
| --- | ---: | ---: |
| AutoRangeAndCompound | 24,310 bytes | 24,310 bytes |
| V3Vault | 22,879 bytes | 22,879 bytes |

AutoRange has 266 bytes of EIP-170 headroom and 10 bytes of project-guard headroom. Preserve the pinned compiler settings and rerun the size guard for future edits. Fork suites were not run; live-chain use here was read-only binding/source verification. No production transactions or Apex lifecycle updates were performed.
