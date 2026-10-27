# Fresh Base Aero deployment rehearsal

Prepared 2026-10-27. Contract source: `aero` commit `44932953b7ba4f380203845d7778a1e8da4da223` (PR #79). The deployment preparation adds scripts, tests and documentation; it does not edit `src/`. **No production deployment has been performed by this preparation.** Rehearsal configuration remains subject to final launch approval.

## Scope and decisions

- Fresh USDC lending vault; collateral tokens USDC, WETH and cbBTC only. No migration of existing loans, lender shares or NFTs. Tokenized equities remain deferred.
- Fresh V3Oracle, InterestRateModel, V3Vault, GaugeManager, V3Utils, LeverageTransformer, AutoRangeAndCompound, AutoExit and FlashloanLiquidator. Foundry also deploys/links the existing VaultLib library where required. Preserve library addresses and build artifacts for verification.
- A replacement V3Utils is required: the earlier `0x8Aa5D777108A5179ed21c9fEfb5023112F950618` predates the ETH-refund fix. Its ownership or verification cannot update its code.
- Only V3Utils, LeverageTransformer and AutoRangeAndCompound are authorized vault transformers. AutoExit operates on wallet positions; it is not a vault transformer. FlashloanLiquidator is permissionless and has no owner.
- Base Safe `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9` owns the fresh IRM immediately and is nominated for the seven Ownable2Step contracts. Those remain deployer-owned until Safe acceptance. No timelock is introduced. At the pinned block the Safe threshold is two, its module list is empty and its guard slot is zero; this is a state observation, not a permanent guarantee.
- Deployer: local Foundry account `deployer`, public address `0x83681C14770b44361e21Faf91D8325423365eA5C`. The user signs the eventual production deployment.
- Existing operator `0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF` and withdrawer `0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82` are carried forward for rehearsal. Both were checked against the old live automators; the withdrawer also matches the old GaugeManager.
- AutoRangeAndCompound defaults remain Advanced 2% / Simple 10%. GaugeManager points to that instance as `compoundModeSource`. These are user-selected modes, not enforced partner tiers. Staking-management cooldown remains the source default of zero blocks; the gauge's own penalty-window protection still applies. Automation TWAP is 60 seconds / 100 ticks.
- Preserve legacy factors: USDC 85%, WETH/cbBTC 77.5%, concentration factors uint32 maximum. USDC lending cap 1,000,000; minimum loan 1; daily increase floors 100,000 each. Reserve factor 10%, reserve protection 5%. New independent IRM: 0% base, 13% utilization multiplier, 300% jump multiplier, 90% kink.
- **Initial debt cap is zero.** Rehearsal activation uses 1,000,000 USDC, matching the pre-wind-down cap. Final opening cap, accounts, economics and zero cooldown require sign-off before production. The Safe activation generator requires an explicit cap and keeps activation separate from ownership acceptance.

## External bindings

The exact constants are in `script/DeployAeroProtocol.s.sol`; pinned read-only evidence is in `base-aero-bindings-53136369.json`. Fork block **53136369**, hash `0x897611fbc514b856136fc06b15f7e340721efeb8afae9da9897b13abc8fd081a`.

| Dependency | Base address / choice |
|---|---|
| NPM | `0x4857DB576eE0e45F10525eC59527BfD10beeC60b` |
| CL factory | `0x9CB220581b91b0C83223012FE69688b92aD07a76` |
| Gauge factory | `0xf437f62053ACB121665b8fDBfeA8F214FB8E589d` |
| Delivered reward asset | Root AERO `0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee` |
| Root handler | `0x8C37F30F3c8fd48bEddb14086fa5148291D422C3` |
| External Universal Router | `0x6fF5693b99212Da76ad316178A184AB56D299b43` |
| 0x AllowanceHolder | `0x0000000000001fF3684f28c67538d4D072C22734` |
| WETH/USDC oracle pool | `0x4a7af46bc8abc00048c6c7920a1488daf568366c`, spacing 50 |
| WETH/cbBTC oracle pool | `0xbb5507daae822ba89c4da61bbfdf4b49a1666bac`, spacing 10 |
| AERO/USDC reward route | `0xd0acf293547457fb4fe9ee32ca93e89497626816`, spacing 200 |
| AERO/WETH reward route | `0xc85d5cb72d1aad6f152a8decad228ae4a59ac9b3`, spacing 200 |
| AERO/cbBTC reward route | `0xe6a7317df4a9a7540663b99a07d1e019caa8afa4`, spacing 200 |

Gauges configured: WETH/USDC spacings 50 and 100; WETH/cbBTC spacings 10 and 1; cbBTC/USDC spacings 50 and 100. A small preflight-only helper is created outside `startBroadcast` to call the shared validator: Foundry forbids the validator’s `address(this)` probe when inlined into a script. That helper is never part of the production deployment. Pool and gauge addresses are resolved/validated against the new factory and root settlement bindings. This gauge list is not a general collateral-pool allowlist. Non-gauged positions composed of configured tokens may still be accepted subject to valuation and risk checks.

Oracle uses WETH reference and USD Chainlink quotes. Preserve legacy feeds, maximum ages, 60-second TWAP verification for USDC/cbBTC, 2% deviation limits and Base sequencer check. The two reference pools change to new Aero pools. Feeds/pools must remain fresh and usable at execution; the script checks feed age, sequencer status, pool liquidity, observations, factory resolution, and gauge/NPM/root-handler bindings.

Sources: [Aero security addresses](https://app.aero.xyz/docs/security/), [Uniswap Base deployments](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-base-deployments), the legacy on-chain baseline and pinned Base reads. The configured Universal Router is a Uniswap router: its encoded swaps use supported Uniswap venues, not Aero's standalone SwapRouter ABI. GaugeManager's own reward compounding swaps directly through the configured Aero pools. Integrators must encode external swaps accordingly or use the supported 0x path; a raw Aero SwapRouter payload is not interchangeable.

## Reproduce the preparation

Work directory on this host:

```bash
cd /home/ubuntu/code/revert-monorepo/.chambers/aerodrome-migration/.chamber-worktrees/lend-aero-launch
```

Use a historical-state-capable Base RPC in `BASE_RPC_URL`. Set it privately in your shell; do not commit credentials. The full rehearsal only needs read-only RPC access. Production signing uses the local encrypted Foundry keystore, not a private key in a script.

```bash
git submodule update --init --recursive
forge build --root fixtures/upstream-gauge
forge test --match-path test/fork/AeroProtocolDeployment.t.sol -vv
AERO_FORK_BLOCK=53136369 bash script/deploy-aero-protocol.sh --dry-run
bash script/check-sizes.sh
```

The fork tests execute the actual deployment script, then impersonate the Safe to accept ownership and activate the test vault. Test actors receive synthetic balances; production feeds, pools, NPM, gauges and root reward delivery execute on the fork. Impersonation is test-only and does not prove the ability to collect production Safe signatures.

## Production execution, after audit and launch approval

1. Pin the reviewed preparation commit and its audited `src/` tree. Recheck upstream `aero`; review any newer changes and rerun validation before changing the pin. Preserve the exact compiler settings and artifacts (Solc 0.8.24, optimizer 25, via IR).
2. Confirm the role addresses, fee policy, cooldown and opening debt cap above. Verify bot/indexer/frontend/liquidator support and fund the deployer for the estimated gas.
3. Rehearse against **latest** Base state; ensure `AERO_FORK_BLOCK` is unset. Verify the displayed configuration and record the result.

```bash
unset AERO_FORK_BLOCK
bash script/deploy-aero-protocol.sh --dry-run
```

4. The user broadcasts, signing with local Foundry `deployer`:

```bash
bash script/deploy-aero-protocol.sh --broadcast
```

5. Verify all contracts and library sources using `ETHERSCAN_API_KEY`. This publishes source to the explorer:

```bash
bash script/deploy-aero-protocol.sh --verify
```

6. Generate Safe files from **successful production receipts**, with the approved cap. Example uses 1,000,000 USDC:

```bash
python3 script/prepare-aero-safe.py \
  broadcast/DeployAeroProtocol.s.sol/8453/run-latest.json \
  --debt-cap-usdc 1000000 --out broadcast/aero-handoff
```

The helper rejects missing/failed receipts, incomplete deployments, wrong chain, wrong ownership/bindings and an already-active debt cap. It writes `addresses.json`, `safe-accept-ownership.json`, and `safe-activate-borrowing.json`. These are local files only; nothing is submitted to Safe. Predicted rehearsal addresses are not production addresses.

7. Import and execute **ownership acceptance only** in the Base Safe. Verify all seven owners equal the Safe, pending owners are zero and IRM owner already equals the Safe. The liquidator has no owner.
8. Use confirmed addresses and deployment blocks to configure indexer, frontend, bots, liquidator and monitoring. No such services are changed by this contract script. Test small real deposits/positions, repay/remove availability, expected gauges and router quotes while borrowing remains disabled. Borrowing tests require the controlled activation stage.
9. After final checks and audit review, import the **separate activation** file. Reconfirm the cap and all risk parameters immediately before signing. `setLimits` changes all five limit fields, so regenerate/review if governance changed any since preparation. Verify the cap, perform a small borrow/repay/stake/exit smoke test and monitor before wider exposure.

## Partial broadcast recovery

Each script call is a separate transaction; a dry-run cannot guarantee later market/state conditions. If receipt retrieval fails, first inspect actual receipts and deployed code using a reliable RPC. Preserve `broadcast/` and `cache/` records. Do not rerun a fresh deployment blindly.

```bash
bash script/deploy-aero-protocol.sh --resume
```

Resume only the same saved sequence after resolving the RPC issue. If a transaction truly reverted, stop and inspect its preconditions; do not repeatedly resend or bypass validation. Finish missing configuration on the already-created contracts using the retained deployer ownership, comparing every intended call against the deployment script. Never bind a different manager to a partially prepared vault: binding is one-time. A fresh deployment is a separate reviewed decision if an immutable/binding is wrong. Ownership acceptance and activation happen only after the full configuration is verified.

## Validation results and limitations

The live fork also reproduces an operational limit: a compound on a small cbBTC position can revert when the reward swap/fee calculation rounds the usable cbBTC amount to zero. The transaction rolls back atomically; rewards remain claimable and normal NFT removal succeeds. Keepers must wait for sufficient rewards and simulate profitability/output before sending, including at least enough output for both position tokens after fees. No contract change is made for this case. This is distinct from the root handler minimum-redemption/deferred-liability accounting.

The exact user wrapper (`AERO_FORK_BLOCK=53136369 bash script/deploy-aero-protocol.sh --dry-run`) also completed successfully without broadcasting.

All **11** fork lifecycle tests passed against the final script: full configuration/ownership checks; initially disabled borrowing; all six pool borrow/stake/claim/repay/remove cycles; reward compounding through all three live routes; V3Utils withdrawal with a real Universal Router swap; leveraged liquidity addition; bot staking consent/revocation and Simple-mode reward fees; staked flashloan liquidation; safe rollback/exit for tiny cbBTC rewards; staked range replacement preserving debt; and wallet AutoExit. The liquidation test uses an explicit governance collateral-factor shock to make a loan liquidatable, rather than claiming to model a real market crash.

This preparation does not replace the pending Cantina scan. Production source verification, Safe signatures, service configuration and market-depth/quote availability at actual launch remain separate from local execution.


## Isolated transaction-sequence rehearsal

The 2026-10-27 rehearsal sent 47 transactions **only to localhost Anvil**, including the VaultLib deployment, followed by seven ownership acceptances and one activation. All receipts succeeded; actual deployment gas totaled 32,690,468 (not a production fee quote). See `aero-local-rehearsal-results.json`. The Safe calls were executed by locally impersonating its address; production Safe signing itself was not exercised.

For an independent repetition, start Anvil in a separate terminal and isolate broadcast/cache output from production records:

```bash
anvil --host 127.0.0.1 --port 28543 --chain-id 8453 \
  --fork-url "$BASE_RPC_URL" --fork-block-number 53136369 --silent
```

In the deployment checkout:

```bash
export AERO_DEPLOYER=0x83681C14770b44361e21Faf91D8325423365eA5C
cast rpc --rpc-url http://127.0.0.1:28543 anvil_impersonateAccount "$AERO_DEPLOYER"
cast rpc --rpc-url http://127.0.0.1:28543 anvil_setBalance "$AERO_DEPLOYER" 0x8ac7230489e80000
FOUNDRY_BROADCAST=broadcast/local-rehearsal FOUNDRY_CACHE_PATH=cache/local-rehearsal \
  forge script script/DeployAeroProtocol.s.sol:DeployAeroProtocol \
  --rpc-url http://127.0.0.1:28543 --sender "$AERO_DEPLOYER" \
  --unlocked --broadcast --slow -vv
BASE_RPC_URL=http://127.0.0.1:28543 python3 script/prepare-aero-safe.py \
  broadcast/local-rehearsal/DeployAeroProtocol.s.sol/8453/run-latest.json \
  --debt-cap-usdc 1000000 --out broadcast/local-rehearsal/handoff
```

Never use the local rehearsal's receipt/address files for production or resume them against a public RPC. The initial chamber rehearsal's records were archived separately after validation. The runbook's production paths should contain only the eventual real deployment.

The contract deployment is ready for review as a concrete configuration, not a declaration of production launch readiness. Before the next scan, include these scripts and bindings in the reviewed repository revision. Production launch still requires audit review, the final configuration decision, source verification and the service wiring described above. No new Cantina scan has been started by this preparation.

The clean source-only and full-build size guards passed (24,320-byte project guard; 24,576-byte EIP-170 limit). Actual deployed runtime sizes are recorded in `aero-local-rehearsal-results.json`; the largest is AutoRangeAndCompound at 24,064 bytes, leaving 512 bytes under EIP-170. The full-build guard ran concurrently with the final deployment-only preflight adjustment; the protocol sources were unchanged throughout, and the final script was independently deployed with all runtime sizes measured on the local node.
