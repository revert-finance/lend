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

## Pancake V3 Protocol Deployment

The full Pancake deployment scripts deploy the vault, oracle, interest model, V3 utilities, automations, flash liquidator, and `PancakeStakingManager`.

Entrypoints:

- Base: `script/DeployPancakeBase.s.sol:DeployPancakeBase`
- BSC: `script/DeployPancakeBsc.s.sol:DeployPancakeBsc`

The scripts hardcode the verified Pancake V3 NPM, `MasterChefV3`, CAKE, wrapped native token, and default vault asset for each chain. Market risk, oracle, ownership, reward-route, and supported-pool config are environment-driven.

### Core Environment

```sh
export PRIVATE_KEY="<DEPLOYER_PRIVATE_KEY>"
export RPC_URL="<BASE_OR_BSC_RPC_URL>"
export OWNER="<OWNER_OR_MULTISIG>"                # optional; if set, ownership is transferred after setup
export OPERATOR="<AUTOMATION_OPERATOR>"           # defaults to deployer
export WITHDRAWER="<AUTOMATION_WITHDRAWER>"       # defaults to deployer
export STAKING_WITHDRAWER="<STAKING_WITHDRAWER>"  # defaults to WITHDRAWER
export UNIVERSAL_ROUTER="<UNIVERSAL_ROUTER>"      # optional, only needed for Universal Router swapData
export ZEROX_ALLOWANCE_HOLDER="<ZEROX_ALLOWANCE_HOLDER>" # optional, only needed for 0x swapData
```

Optional overrides:

```sh
export VAULT_ASSET="<LENDING_ASSET>"              # Base default: USDC; BSC default: USDT
export REFERENCE_TOKEN="<ORACLE_REFERENCE_TOKEN>" # Base default: WETH; BSC default: WBNB
export CHAINLINK_REFERENCE_TOKEN="0x0000000000000000000000000000000000000000"
export VAULT_NAME="<ERC20_NAME>"
export VAULT_SYMBOL="<ERC20_SYMBOL>"
export SET_VAULT_GAUGE_MANAGER="true"            # one-shot vault binding; defaults true
```

### Oracle, Risk, And Pool Config

Production deployments require these arrays unless `ALLOW_EMPTY_CONFIG=true` is set for dry-run only.

```sh
# Oracle modes: 1=CHAINLINK_TWAP_VERIFY, 2=TWAP_CHAINLINK_VERIFY, 3=CHAINLINK, 4=TWAP
export ORACLE_TOKENS="<TOKEN_A>,<TOKEN_B>"
export ORACLE_FEEDS="<CHAINLINK_FEED_A>,<CHAINLINK_FEED_B>"
export ORACLE_MAX_FEED_AGES="86400,86400"
export ORACLE_TWAP_POOLS="<POOL_A_OR_ZERO>,<POOL_B_OR_ZERO>"
export ORACLE_TWAP_SECONDS="60,60"
export ORACLE_MODES="1,3"
export ORACLE_MAX_DIFFERENCES="200,0"

export COLLATERAL_TOKENS="<TOKEN_A>,<TOKEN_B>"
export COLLATERAL_FACTORS_BPS="8500,7750"
export COLLATERAL_VALUE_LIMIT_FACTORS_BPS="10000,10000" # 10000 means no per-token debt cap

export GLOBAL_LEND_LIMIT="<ASSET_UNITS>"
export GLOBAL_DEBT_LIMIT="<ASSET_UNITS>"
export DAILY_LEND_INCREASE_LIMIT_MIN="<ASSET_UNITS>"
export DAILY_DEBT_INCREASE_LIMIT_MIN="<ASSET_UNITS>"
export MIN_LOAN_SIZE="<ASSET_UNITS>"

export PANCAKE_REWARD_BASE_TOKENS="<TOKEN0>,<TOKEN1>"
export PANCAKE_REWARD_BASE_POOLS="<CAKE_TOKEN0_POOL>,<CAKE_TOKEN1_POOL>"
export PANCAKE_STAKING_POOLS="<SUPPORTED_LP_POOL>"
```

### Dry-Run

```sh
ALLOW_EMPTY_CONFIG=true forge script script/DeployPancakeBase.s.sol:DeployPancakeBase \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  -vvvv
```

```sh
ALLOW_EMPTY_CONFIG=true forge script script/DeployPancakeBsc.s.sol:DeployPancakeBsc \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  -vvvv
```

### Broadcast

```sh
forge script script/DeployPancakeBase.s.sol:DeployPancakeBase \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

```sh
forge script script/DeployPancakeBsc.s.sol:DeployPancakeBsc \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

The script enforces:

- chain ID matches the selected script
- configured addresses have code
- `MasterChefV3.CAKE()` matches the chain CAKE address
- `MasterChefV3.nonfungiblePositionManager()` matches the chain Pancake V3 NPM
- reward route pools resolve through the Pancake V3 factory
- staking pools are registered in `MasterChefV3.v3PoolAddressPid(pool)` and `poolInfo(pid).v3Pool`

### Post-Deploy Verification

1. `V3Vault.gaugeManager()` equals the deployed `PancakeStakingManager` when `SET_VAULT_GAUGE_MANAGER=true`.
2. `PancakeStakingManager.poolToGauge(<POOL>)` equals `PANCAKE_MASTER_CHEF_V3` for every configured staking pool.
3. `PancakeStakingManager.rewardBasePools(<TOKEN>)` is set for every configured reward route.
4. `PancakeStakingManager.withdrawer()` equals the configured staking withdrawer.
5. Run the focused Base fork smoke test:

```sh
forge test --match-path test/integration/base/PancakeBaseFork.t.sol
```

## Note About Uniswap v3 PoolAddress Hash

If you run legacy mainnet integration/deployment paths that depend on `PoolAddress.sol`, confirm the expected `POOL_INIT_CODE_HASH` for the target deployment path.
