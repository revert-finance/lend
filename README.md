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

For gauge configuration (step 2):

```sh
export GAUGE_MANAGER="<DEPLOYED_GAUGE_MANAGER_ADDRESS>"
export WETH_USDC_GAUGE="0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8"
export CBBTC_USDC_GAUGE="0x6399ed6725cC163D019aA64FF55b22149D7179A8" # optional
```

### Step 1: Deploy Protocol Contracts

```sh
forge script script/DeployAerodromeProtocol.s.sol:DeployAerodromeProtocol \
  --rpc-url "$ETH_RPC_URL" \
  --broadcast \
  -vvvv
```

The script enforces:
- `block.chainid == 8453` (Base mainnet only)
- configured addresses have code
- NPM factory wiring is correct
- configured Slipstream pools resolve correctly through Aerodrome factory

Record deployed `VAULT`, `GAUGE_MANAGER`, `ORACLE`, `IRM`, and transformer addresses from logs.

### Step 2: Configure Gauges

```sh
forge script script/ConfigureGauges.s.sol:ConfigureGauges \
  --rpc-url "$ETH_RPC_URL" \
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
5. Run focused fork smoke tests:

```sh
forge test --match-contract V3VaultAerodromeTest
forge test --match-test testFlashloanLiquidationHappyPath
```

## Note About Uniswap v3 PoolAddress Hash

If you run legacy mainnet integration/deployment paths that depend on `PoolAddress.sol`, confirm the expected `POOL_INIT_CODE_HASH` for the target deployment path.
