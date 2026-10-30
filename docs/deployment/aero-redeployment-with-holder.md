# Aero redeployment with PoolPeach (historical)

For the current product name and factory-only replacement, use [Poolside deployment](../POOLSIDE_SIMPLE_DEPLOYMENT.md). The source revision and rehearsal results below describe the earlier PoolPeach-named deployment.

Prepared from Aero commit `22d22378ad19f4d9643ca19735d587e8e6effdb7`, which includes PRs #81 and #82. The only additional protocol-source change is the explicit `payable` cast in the PoolPeach factory constructor required by GaugeManager's newly added ETH receiver. Its fork test needs the same cast. This is not a change to permissions or execution behavior.

## Deployment boundary

Deploy a fresh Oracle, IRM, vault, V3Utils, GaugeManager, LeverageTransformer, AutoRangeAndCompound, AutoExit, liquidator and PoolPeach factory, plus the linked VaultLib. The factory deploys individual holders when users create positions; there is no individual holder to deploy now. The previous suite remains untouched. This does not migrate balances or positions.

The existing script retains the approved USDC/WETH/cbBTC collateral, oracle settings, the six required lending-pool gauges plus all other compatible activated Aero gauges, reward routes, 5% Advanced/fallback and 10% Simple fees, operator, withdrawer and Safe. Global debt limit remains zero. It binds the vault staking policy, deploys the factory after all its dependencies are configured, and authorizes the factory on AutoExit before nominating the Safe. The factory has no owner; seven two-step ownership acceptances remain, and IRM ownership transfers immediately.

## Commands

Use the isolated `lend-aero-redeployment` checkout, not the prior `lend-aero-launch` checkout whose broadcast records describe the previous deployment. The wrapper accepts `BASE_RPC_URL` or derives it from an existing `ALCHEMY_API_KEY`. Keep the key in the environment.

```bash
bash script/deploy-aero-protocol.sh --dry-run
bash script/deploy-aero-protocol.sh --broadcast
bash script/deploy-aero-protocol.sh --verify
```

Broadcast uses the local encrypted Foundry account `deployer` (public address `0x83681C14770b44361e21Faf91D8325423365eA5C`). The human enters its password locally. Do not run the old completion script: it targets the previous deployment. Preserve all new broadcast records. On failure, inspect the receipts and failed call before resuming the saved sequence; do not create another fresh suite blindly.

After successful deployment, generate the Safe acceptance file from confirmed receipts:

```bash
export BASE_RPC_URL="${BASE_RPC_URL:-https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY:?}}"
python3 script/prepare-aero-safe.py \
  broadcast/DeployAeroProtocol.s.sol/8453/run-latest.json \
  --ownership-only --out broadcast/aero-handoff
```

The checker verifies the new permanent staking policy, factory's immutable bindings and AutoExit operator permission as well as the prior suite configuration. It produces no borrowing activation file in this mode. The Safe is `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9`.

## Revert integration after broadcast

Update existing monorepo PR #1423 (`codex/aero-vault-staging-integration`) using confirmed creation receipts and deployment blocks. Update frontend and backend address registries, ABIs where necessary, the deployment manifest, tests and context documents. Retain the old manifest as historical evidence. Record the PoolPeach factory separately; deploying it does not implement PoolPeach beneficiary indexing, keeper routing or its one-transaction creation UI.

Keep `AERO_LEND_ENABLED` enabled only for the staging build and disabled in production. Do not use dry-run predictions as deployed addresses. Verify source before marking the new manifest source-verified. Reconcile the integration branch with develop and repeat its relevant checks after the address update.

## Evidence

The live Base dry-run completed with ten contracts plus VaultLib and approximately 48.93 million estimated gas (including Foundry's estimate padding). No production transactions were sent. Runtime sizes: AutoRangeAndCompound 24,223 bytes, V3Vault 22,879, GaugeManager 23,195, PoolPeachFactory 18,410 and PoolPeachPosition 9,438; all are below EIP-170.

At Base block 53,254,303, the prior staging vault had zero lender shares, debt shares, debt cap, USDC balance and directly held NFTs. These reads are not an enumeration of gauge-held positions. The deployment does not modify or sweep that vault.

The two targeted fork suites passed all **61 tests**: 45 holder regressions against the previous deployed dependencies and 16 deployment/lifecycle tests against a newly created suite. The new suite tests include one-transaction holder creation with initial staking, manual NFT withdrawal, keeper staking and automatic exit followed by beneficiary NFT retrieval, all with borrowing disabled.

The separate localhost rehearsal executed **50 transactions**, all with successful receipts (37,191,951 gas used). All **59 Safe-handoff scenarios passed**, including rejection after revoking the factory's AutoExit permission. Local receipts are stored separately under `broadcast/local-rehearsal/` and must never be used as production receipts.

PoolPeach remains outside Cantina scan #18's reviewed revision. Fork tests and a successful rehearsal establish tested behavior, not audit approval or production activation.

## Historical recovery compatibility

`prepare-aero-safe.py --recovery-broadcast` remains limited to the original reserve-factor failure and its exact 13-call recovery suffix. After that sequence is validated, the checker expects the historical nine-contract suite and omits the factory and `stakingPolicy()` checks, which that deployment cannot satisfy. Fresh deployments still require all ten contracts, the staking policy, factory bindings and its AutoExit authorization. Simply supplying the recovery flag cannot downgrade checks for a fresh deployment.

To run the historical regressions, fork Base at block 53168029 on localhost and pass the retained original and completion broadcast files:

```bash
python3 test/deployment/aero_safe_handoff.py --rpc-url http://127.0.0.1:28549 \
  --broadcast ../lend-aero-launch/broadcast/DeployAeroProtocol.s.sol/8453/run-latest.json \
  --recovery-broadcast ../lend-aero-launch/broadcast/CompleteAeroProtocolDeployment.s.sol/8453/run-latest.json
```

The test changes only localhost state and restores each case. For a newly deployed localhost suite, run it without `--recovery-broadcast` and pass that suite's local broadcast record. These changes affect only handoff validation and tests; contract bytecode and deployment transactions are unchanged.

Recovery-fix validation: reproduced the original failure before the change; all **60 historical-recovery scenarios** and **61 fresh-deployment scenarios** passed after it on separate localhost forks. The fresh suite again completed all 50 deployment transactions successfully on localhost.

For full-factory registration and periodic new/replacement gauge updates, use [Aero gauge synchronization](aero-gauge-sync.md).
