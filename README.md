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

Optional V3Utils selection:

```sh
# Unset or zero address: deploy a fresh V3Utils for test deployments.
unset V3_UTILS

# Later real deployment: reuse the existing Aerodrome V3Utils.
export V3_UTILS="0x7D1F9FC22beD0798cDA3Fdb18b14a96fc838B9E1"
```

When `V3_UTILS` is set, the protocol deployer does not call `V3Utils.setVault`. The `V3Utils.owner()` must authorize the deployed vault independently after step 1.

For V3Utils and gauge configuration:

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
- `V3_UTILS` points at a compatible Aerodrome V3Utils when supplied; otherwise a fresh V3Utils is deployed

Record deployed `VAULT`, `GAUGE_MANAGER`, `ORACLE`, `IRM`, `V3_UTILS`, and transformer addresses from logs. `V3_UTILS_DEPLOYED` and `V3_UTILS_VAULT_CONFIGURED` are `true` only for fresh test deployments.

### Step 2: Configure Existing V3Utils

Skip this step when `V3_UTILS_DEPLOYED` is `true`.

Generate the owner/multisig call data:

```sh
forge script script/ConfigureV3Utils.s.sol:ConfigureV3Utils \
  --rpc-url "$ETH_RPC_URL"
```

For a multisig-owned V3Utils, submit a transaction from the `V3Utils.owner()` with:
- target: `V3_UTILS`
- value: `0`
- data: logged `SET_VAULT_CALLDATA`

If the V3Utils owner is an EOA available locally, the same script can broadcast:

```sh
export BROADCAST_V3_UTILS_CONFIG=true

forge script script/ConfigureV3Utils.s.sol:ConfigureV3Utils \
  --rpc-url "$ETH_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

The script enforces:
- `block.chainid == 8453`
- `V3_UTILS` and `VAULT` have code
- `V3Vault.transformerAllowList(V3_UTILS) == true`
- broadcaster is `V3Utils.owner()` when `BROADCAST_V3_UTILS_CONFIG=true`

### Step 3: Configure Gauges

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

### Post-Deploy Verification

1. `V3Vault.gaugeManager()` equals deployed `GaugeManager`.
2. `GaugeManager.poolToGauge(WETH_USDC_POOL)` is set.
3. Optional: `GaugeManager.poolToGauge(CBBTC_USDC_POOL)` is set.
4. `V3Vault.transformerAllowList(<transformer>) == true` for intended transformers.
5. `V3Utils.vaults(<VAULT>) == true`; this is automatic for fresh test deployments and independent for existing V3Utils.
6. Run focused fork smoke tests:

```sh
forge test --match-contract V3VaultAerodromeTest
forge test --match-test testFlashloanLiquidationHappyPath
```

## Note About Uniswap v3 PoolAddress Hash

If you run legacy mainnet integration/deployment paths that depend on `PoolAddress.sol`, confirm the expected `POOL_INIT_CODE_HASH` for the target deployment path.
