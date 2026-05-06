# Revert Lend

Smart contracts for the Revert Lend protocol.

## Setup

1. Install Foundry: https://book.getfoundry.sh/getting-started/installation
2. Install dependencies:

```sh
forge install
```

## Tests

Most suites run on forked chains.

```sh
forge test
```

For Base fork tests, set one of:

```sh
export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/<KEY>"
```

or:

```sh
export ANKR_API_KEY="<KEY>"
```

## Base Deployment Runbook (Aerodrome Slipstream)

### Required Environment Variables

```sh
export PRIVATE_KEY="<DEPLOYER_PRIVATE_KEY>"
export ETH_RPC_URL="<BASE_RPC_URL>"
```

The Aerodrome deployment script always deploys a fresh `V3Utils` and configures the deployed vault on it during the same broadcast.

Production roles are hardcoded in the deployment script:

- Base multisig / owner: `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9`
- Multichain withdrawer: `0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82`
- Multichain operator: `0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF`

For gauge configuration:

```sh
export VAULT="<DEPLOYED_VAULT_ADDRESS>"
export GAUGE_MANAGER="<DEPLOYED_GAUGE_MANAGER_ADDRESS>"
export WETH_USDC_GAUGE="0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8"
export CBBTC_USDC_GAUGE="0x6399ed6725cC163D019aA64FF55b22149D7179A8" # optional
```

### Step 1: Deploy Protocol Contracts

```sh
forge script script/DeployAerodromeProtocol.s.sol:DeployAerodromeProtocol \
  --rpc-url "$ETH_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

The script enforces:
- `block.chainid == 8453` (Base mainnet only)
- configured addresses have code
- NPM factory wiring is correct
- configured Slipstream pools resolve correctly through Aerodrome factory
- fresh protocol contracts are deployed, including `V3Utils`
- production owner, withdrawer, and operator roles are configured

Record deployed `VAULT`, `GAUGE_MANAGER`, `ORACLE`, `IRM`, `V3_UTILS`, and transformer addresses from logs. `V3_UTILS_DEPLOYED` and `V3_UTILS_VAULT_CONFIGURED` should both log `true`.

### Step 2: Configure Gauges

```sh
forge script script/ConfigureGauges.s.sol:ConfigureGauges \
  --rpc-url "$ETH_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

The script enforces:
- `block.chainid == 8453`
- deployer is `GaugeManager.owner()`
- pool/gauge addresses have code
- provided gauge matches `pool.gauge()` before broadcasting

Run gauge configuration before the Base multisig accepts `GaugeManager` ownership. If ownership has already been accepted, run this step from the Base multisig instead.

### Step 3: Accept Ownership

After gauge configuration is complete, the Base multisig should call `acceptOwnership()` on:

- `ORACLE`
- `VAULT`
- `GAUGE_MANAGER`
- `V3_UTILS`
- `LEVERAGE_TRANSFORMER`
- `AUTO_RANGE`
- `AUTO_EXIT`

`InterestRateModel` uses single-step ownership transfer, so its owner is set to the Base multisig during deployment.

### Post-Deploy Verification

1. `V3Vault.gaugeManager()` equals deployed `GaugeManager`.
2. `GaugeManager.poolToGauge(WETH_USDC_POOL)` is set.
3. Optional: `GaugeManager.poolToGauge(CBBTC_USDC_POOL)` is set.
4. `V3Vault.transformerAllowList(<transformer>) == true` for intended transformers.
5. `V3Utils.vaults(<VAULT>) == true`.
6. `GaugeManager.withdrawer()`, `AutoRangeAndCompound.withdrawer()`, and `AutoExit.withdrawer()` equal `0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82`.
7. `AutoRangeAndCompound.operators(0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF)` and `AutoExit.operators(0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF)` are `true`.
8. Ownership has been accepted by `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9`.
9. Run focused fork smoke tests:

```sh
forge test --match-contract V3VaultAerodromeTest
forge test --match-test testFlashloanLiquidationHappyPath
```

## Note About Uniswap v3 PoolAddress Hash

If you run legacy mainnet integration/deployment paths that depend on `PoolAddress.sol`, confirm the expected `POOL_INIT_CODE_HASH` for the target deployment path.
