# Fresh Aero deployment with USDC as the oracle reference

This is an alternative to the three TWAP adapters in PR #119, stacked on the stock configuration
proposal in PR #118. Choose one approach; do not apply both activation runbooks. No `src/` contract
implementation changes are needed for this option. A new vault is required because its oracle address
is immutable, and a new GaugeManager and Poolside factory are required because their vault bindings
are immutable. The script deploys a coherent fresh suite, rather than mixing old and new bindings.

Existing positions, debts, lender shares and holder balances remain on the old deployment. Internal
test accounts must repay, withdraw and recreate positions as needed. This is not an automatic migration.

## Oracle configuration

`AERO_ORACLE_USDC_REFERENCE=true` selects `new V3Oracle(npm, USDC, address(0))`. The final zero
means that Chainlink answers are USD-denominated. It does **not** peg USDC to one dollar: conversion
of other assets divides their USD answer by the USDC/USD answer.

| Asset | Existing WETH-reference policy | Fresh USDC-reference policy |
|---|---|---|
| USDC | Chainlink plus USDC/WETH TWAP | Reference unit; USD feed retained for other-asset conversion |
| WETH | Chainlink | Chainlink plus WETH/USDC TWAP |
| cbBTC | Chainlink plus cbBTC/WETH TWAP | Chainlink plus cbBTC/USDC TWAP |
| Stocks, separately approved | Direct Chainlink in original #118 | Chainlink plus stock/USDC TWAP |

TWAP windows remain 60 seconds and tolerances 200 basis points. The actual position-pool spot guard
remains 200 basis points. Changing the direction of a price ratio makes a percentage tolerance slightly
asymmetric at its boundary, so this is not a promise of identical acceptance decisions in every state.
The cbBTC reference venue also changes. The script probes the new basic-asset valuations before
recording broadcast transactions. Without the environment flag, the original WETH-reference deployment
path remains available; keep the chosen flag consistent throughout rehearsal and deployment.

## Verified external dependencies

Network: Base mainnet, chain ID 8453. NPM `0x4857DB576eE0e45F10525eC59527BfD10beeC60b`, factory
`0x9CB220581b91b0C83223012FE69688b92aD07a76`; routers, feeds, gauges and roles are otherwise unchanged.

| Reference | Address |
|---|---|
| WETH/USDC pool | `0x4a7af46bc8abc00048c6c7920a1488daf568366c` |
| cbBTC/USDC pool, tick spacing 100 | `0x784e539f15ca2d19449a6311c5dab6cf37d8f1ba` |
| WETH/USD feed | `0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70` |
| cbBTC/USD feed | `0x07da0e54543a844a80abe69c8a12f22b3aa59f9d` |
| USDC/USD feed | `0x7e860098f58bbfc8648a4311b374b1d669a2bc6b` |

At Base block **56574886**, canonical factory lookup confirmed two cbBTC/USDC pools at spacing 50 and
100. Both had active liquidity and a working 60-second observation. The selected spacing-100 pool held
1,145,659.511777 USDC and 38.69232475 cbBTC. Balances include fees and are not a claim of executable
liquidation depth. This pool was already among the six configured lending pools. Deployment rechecks
pool provenance, active liquidity, observation availability and oracle agreement; do not rely solely
on the historical snapshot.

## Fees and valuation

No fee formulas or settings change. Advanced/fallback compounding remains 5%, Simple remains 10%,
and the lending reserve factor remains 10%. AERO reward base pools, swap routing, permission checks,
staking windows and fee recipients remain as in the existing deployment script.

The oracle converts raw token amounts and LP fees into the requested output token using its reference
price ratios. USDC's six decimals must be handled both for principal and accumulated fees; this is
tested against an independently configured WETH-reference oracle using the same feed answers. The
`ignoreFees` path used for staked collateral must still exclude LP fee value. The inherited deployment
suite exercises fee/reward compounding, the Simple fee choice and operator-managed staking transitions.

The reference change does not make stock collateral safe by itself. TWAP or freshness failures block
liquidation as well as borrowing. Stock admission, liquidity/stress limits and 24/7 feed support remain
separate decisions. See [stock collateral preparation](aero-stock-collateral.md).

## Deployment commands

Use the checkout containing this draft. Required tools are Foundry and Python 3. Use the existing local
Foundry account `deployer`; do not place its password or private key in the repository. The deployer
must be `0x83681C14770b44361e21Faf91D8325423365eA5C`. The wrapper accepts `BASE_RPC_URL`, or constructs
the Base Alchemy URL from the existing `ALCHEMY_API_KEY`. No new RPC credentials are required.

```bash
export AERO_ORACLE_USDC_REFERENCE=true
AERO_FORK_BLOCK=56574886 bash script/deploy-aero-protocol.sh --dry-run
```

The deployment script registers compatible gauges across the factory and configures USDC, WETH and
cbBTC only. It leaves stock feeds/collateral unset and the global debt cap at zero, following the existing
fresh-stack commissioning workflow. It nominates the existing Base Safe, sets the existing operator and
withdrawer, binds all new contracts together, and authorizes the new holder factory for AutoExit.

Once deployment is approved, pause all Base bots that use the deployer account, unset any pinned fork
block, and rehearse at current state before broadcasting:

```bash
unset AERO_FORK_BLOCK
export AERO_ORACLE_USDC_REFERENCE=true
bash script/deploy-aero-protocol.sh --dry-run
bash script/deploy-aero-protocol.sh --broadcast
```

Do not rerun fresh deployment after a partial broadcast. Inspect receipts/nonces and use the existing
`--resume` path with the original record and the same environment. The initial script simulation does
not make the individual broadcast transactions atomic. Do not use completion scripts pinned to old vaults.

With `ETHERSCAN_API_KEY` available, verify the exact new sources and constructor arguments:

```bash
bash script/deploy-aero-protocol.sh --verify
```

The existing verifier reads the confirmed broadcast and its actual constructor arguments, including
USDC as the oracle reference. It verifies the ten protocol contracts and three libraries/deployer helpers.

## Ownership, activation and integration handoff

After all receipts succeed, use the existing Safe preparation helper with the new explicit policy flag.
For this helper, export `BASE_RPC_URL` in the shell (the deployment wrapper's exported URL does not persist
in its parent shell). It checks the actual oracle reference and all three complete feed configurations.
Broad extra gauge mappings must resolve to the canonical factory, correct pool/NPM/gauge factory, the
same voter as the required gauges and an active gauge; they are not accepted merely because they exist.

```bash
python3 script/prepare-aero-safe.py \
  broadcast/DeployAeroProtocol.s.sol/8453/run-latest.json \
  --usdc-reference --debt-cap-usdc 1000000 --out /tmp/aero-usdc-reference-handoff
```

Review the generated ownership and activation files. The Safe
`0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9` accepts pending ownership and, when ready, executes the
separate 1,000,000 USDC global-debt-cap activation for the basic assets. Use `--ownership-only` instead
of `--debt-cap-usdc` if commissioning should continue with borrowing disabled. This PR executes neither.
Run this strict basic-asset handoff **before** adding stock feeds/collateral.

Then prepare the stock oracle calls and, after live TWAP valuations succeed and stock risk approval is
complete, the separate stock collateral calls using the confirmed fresh vault/oracle addresses. No
adapters or further core-contract deployments are required for that stage.

Record final confirmed addresses and deployment blocks from receipts; do not copy dry-run predictions.
Update the Revert deployment manifest, feature-gated frontend addresses/ABIs, indexer registration and
URLs as applicable, automation/compounder/liquidator targets, gauge-sync manager target, source links
and the shared address documentation. Give the Poolside integrator the new factory and its bound suite;
holders from the old factory remain bound to the old suite. Actual integration edits follow deployment
because the final addresses do not exist yet. Keep old test positions discoverable until cleaned up.

## Validation commands

```bash
forge test --match-contract AeroUsdcReferenceTest -vv
forge test --match-path test/fork/AeroStockCollateral.t.sol \
  --fork-url "$BASE_RPC_URL" --fork-block-number 56276522 -vv
```

`AeroUsdcReferenceTest` uses the existing deployment suite's pinned Base block 53136369 and switches
only the oracle-reference selection. Stock tests use live feeds/pools but shim B20 decimals and use
synthetic NFT metadata where indicated. They do not prove full native-B20 stock lending execution.

## Rehearsal results

- USDC-reference deployment fork suite: **20 passed** at Base block 53136369, including all six
  basic-asset lending pools, staking transitions, fee/reward compounding, Simple fee charging,
  leverage, range changes, exits and flash-loan liquidation.
- Original WETH-reference deployment suite: **17 passed** at the same block.
- Stock configuration/valuation suite: **6 passed** at Base block 56276522, including all three
  stock/USDC checks, fee conversion and rejection of a divergent Chainlink answer.
- Full USDC-reference deployment dry-run: **passed** at Base block 56574886; 322 transactions,
  624 factory pools inspected and 276 compatible gauges configured. Gas estimate: 102,102,363.
  This is a simulation, not a deployment. No final addresses are declared by this PR.

The same 322 transactions were replayed successfully on a local Anvil fork of block 56574886.
`prepare-aero-safe.py --usdc-reference` then validated the complete configuration (including all
276 gauges) and produced the ownership/activation files at local block 56575208. Omitting the
USDC-reference flag was correctly rejected. This rehearsal sent transactions only to localhost.

The principal/LP-fee comparison permits two raw USDC units of rounding (0.000002 USDC).
These historical rehearsals do not replace a current-state rehearsal before broadcasting.
