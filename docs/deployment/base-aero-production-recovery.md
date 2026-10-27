# Base Aero deployment recovery (completed)

The user broadcast the preparation on 2026-10-27. All nine contracts and VaultLib were deployed. The first 34 transactions succeeded; transaction 35 failed at Base block 53165756:

- Hash: `0x9293cc9f4a176da7b63894686db1018369f892d688eac52881f96593b4c2995a`
- Vault: `0x1c69eb478425199D34D93484c76c1B39554979a1`
- Call: `setReserveFactor(429496729)`
- Gas limit and gas consumed: **49,834**. The live `debug_traceTransaction` reports **out of gas**.

`setReserveFactor` updates global interest. The deployment simulation runs at one timestamp, so it can skip the elapsed-time interest calculation. Sequential production transactions cross blocks and take the more expensive path. Additional account funding does not fix this transaction gas limit. The deployer held approximately 0.02538 ETH when checked after the failure.

At checked block 53165818, all eight ownable contracts still belonged to the deployer, the seven pending-owner values were zero, the debt limit was zero, and the vault had zero lender shares and debt shares. Reserve factor remained zero and reserve protection remained at its constructor default. Ownership nominations and the IRM transfer had not executed. The remaining configuration is therefore **13 calls**: retry the reserve factor, set reserve protection and three collateral configs, then perform the eight ownership transfers/nominations. No contracts need redeployment and no protocol source changes are needed.

## Complete the existing deployment

Do not restart the original deployment or resume its original saved sequence: the failed nonce has been consumed, and a replay must include the failed configuration call. Preserve the original record and failure evidence.

```bash
source .env
unset AERO_FORK_BLOCK
bash script/complete-aero-deployment.sh --dry-run
bash script/complete-aero-deployment.sh --broadcast
```

The user signs with the same encrypted Foundry account `deployer`. This recovery targets only the exact deployed addresses. Its preflight checks Base, deployer ownership, vault bindings, unused vault state and disabled borrowing. Each call has explicit gas headroom; the reserve-factor call has a 250,000 gas allowance. No CREATE calls or borrowing activation are included. The original deployment script also now supplies explicit gas for the reserve-factor call for future deployments.

If recovery itself fails partway, preserve its record and inspect state before retrying. The wrapper refuses a second fresh broadcast once a recovery record exists; do not bypass that check.

## Handoff after successful recovery

```bash
python3 script/prepare-aero-safe.py \
  broadcast/DeployAeroProtocol.s.sol/8453/run-latest.json \
  --recovery-broadcast broadcast/CompleteAeroProtocolDeployment.s.sol/8453/run-latest.json \
  --ownership-only --out broadcast/aero-ownership
```

The helper preserves the original failed-transaction evidence, requires that it is the known failed transaction, and matches all 13 recovery calls against the original incomplete suffix by sender, target, calldata, value and chain. It checks the successful original prefix and every recovery receipt, then runs the existing full live configuration validation. It does not discard an arbitrary failed transaction or infer completion from a local simulation.

The generated `safe-accept-ownership.json` is for the Base Safe `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9`. Seven contracts remain deployer-owned until Safe acceptance; InterestRateModel transfers directly to the Safe during recovery. Borrowing remains disabled.

## Validation

- Recovery wrapper passed a broadcast-disabled simulation against current Base state.
- Rehearsal forked the **actual partial production deployment** at block 53165818, without deploying replacement contracts.
- All **13 recovery transactions** succeeded on localhost. The reserve-factor retry used **62,256 gas**, above the failed transaction's 49,834 allowance.
- The recovered-receipt handoff helper passed all existing configuration checks and generated seven ownership acceptances with no borrowing activation file.
- These checks did not sign or send recovery transactions to production.

Production evidence is retained locally under `broadcast/aero-recovery-evidence/`; recovery-fork records are isolated under `broadcast/recovery-local-test/` and must not be used as production records. Original source/build artifacts and original deployment receipts remain available for explorer verification.


## Production completion — 2026-10-27

The user signed all 13 recovery calls successfully (starting at block **53166247**). The reserve-factor retry used 62,256 gas. The receipt-validation and ownership-only handoff helper then passed against live Base at block **53166282**. The generated batch contains seven Safe ownership acceptances; it has not been submitted. InterestRateModel is already Safe-owned. Borrowing remains disabled.

All nine deployed contracts and VaultLib have verified source on BaseScan. Verification signs no transactions:

```bash
bash script/deploy-aero-protocol.sh --verify
```

This uses individual `forge verify-contract` calls, not `forge script --resume --verify`; the latter requires broadcasting in the installed Foundry version and must not be used to replay the original failed sequence.

V3Vault required reconstructing its original 95-file compilation batch from build ID `663187fb3802fbc0`. Its 46 dependency source files match the deployed artifact; unrelated batch inputs came from the earlier compilation context. The reconstructed Solidity standard JSON input produced **byte-for-byte identical creation bytecode** before library linking. Its accepted input is preserved locally at `broadcast/aero-source-verification/V3Vault.standard-json.json`; BaseScan also publishes the verified input. The other contracts were verified independently from their own artifacts. Preserve the original build artifacts and verification input rather than recompiling this historical deployment with a different batch.
