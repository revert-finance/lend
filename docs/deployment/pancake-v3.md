# Pancake V3 Deployment Runbook

This runbook covers the Pancake V3 branch deployment path for Base and BSC. It assumes the full protocol deploy scripts are used:

- Base: `script/DeployPancakeBase.s.sol:DeployPancakeBase`
- BSC: `script/DeployPancakeBsc.s.sol:DeployPancakeBsc`

## 1. Pick And Fill The Environment

Start from one of the chain templates:

```sh
cp deployments/pancake/base.env.example deployments/pancake/base.env
cp deployments/pancake/bsc.env.example deployments/pancake/bsc.env
```

Fill every `<...>` placeholder before sourcing the file. The templates include verified Pancake V3, MasterChefV3, CAKE, Chainlink, TWAP, staking pool, and reward route addresses for the default market on each chain.

Do not deploy production with `ALLOW_EMPTY_CONFIG=true`. That flag is only for checking constructor and external-address wiring without risk, oracle, staking, or reward route config.

## 2. Required Operator Decisions

These values are intentionally not hardcoded:

- `OWNER`: final owner or multisig.
- `OPERATOR`: automation account for AutoRange and AutoExit.
- `WITHDRAWER`: protocol fee withdrawer for automators.
- `STAKING_WITHDRAWER`: protocol fee or dust withdrawer for `PancakeStakingManager`.
- `ORACLE_EMERGENCY_ADMIN` and `VAULT_EMERGENCY_ADMIN`: emergency admin accounts, or zero if not used at launch.
- `UNIVERSAL_ROUTER` and `ZEROX_ALLOWANCE_HOLDER`: set to zero unless external router swap paths will be enabled immediately.
- Collateral factors, collateral value limit factors, lend/debt limits, daily increase limits, and minimum loan size.
- Initial supported Pancake LP pools beyond the default Base WETH/USDC or BSC WBNB/USDT pool.

## 3. Dry Run

Source the completed env file, then dry-run without broadcasting:

```sh
source deployments/pancake/base.env
forge script script/DeployPancakeBase.s.sol:DeployPancakeBase \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  -vvvv
```

```sh
source deployments/pancake/bsc.env
forge script script/DeployPancakeBsc.s.sol:DeployPancakeBsc \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  -vvvv
```

The dry run should fail rather than silently deploy if any production config is empty, a Chainlink feed/pool address has no code, a reward route does not resolve through the Pancake V3 factory, or a staking pool is not registered in `MasterChefV3`.

## 3.1 Pancake Staking Invariant

Staking is supported only for debt-free vault positions. The vault rejects borrowing against already-staked Pancake NFTs and rejects staking NFTs with open debt. Reward compounding is also restricted to debt-free staked positions.

This is intentional. Pancake MasterChefV3 can timelock both `withdraw` and direct staked `decreaseLiquidity` after liquidity updates, so allowing debt on staked positions would make liquidation depend on an external unlock window.

## 4. Broadcast

After the dry run is clean:

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

Copy the logged deployment addresses back into the env file:

- `INTEREST_RATE_MODEL`
- `ORACLE`
- `VAULT`
- `FLASHLOAN_LIQUIDATOR`
- `V3_UTILS`
- `LEVERAGE_TRANSFORMER`
- `AUTO_RANGE`
- `AUTO_EXIT`
- `PANCAKE_STAKING_MANAGER`

## 5. Accept Ownership

If `OWNER` was set, ownership is transferred at the end of the deployment.

`InterestRateModel` uses one-step ownership and should already be owned by `OWNER`.

These contracts use `Ownable2Step`; the `OWNER` account must call `acceptOwnership()` on each:

- `ORACLE`
- `VAULT`
- `V3_UTILS`
- `LEVERAGE_TRANSFORMER`
- `AUTO_RANGE`
- `AUTO_EXIT`
- `PANCAKE_STAKING_MANAGER`

The verification script accepts either state for two-step contracts: owner already accepted, or `OWNER` still pending.

## 6. Verify Deployment Wiring

Run:

```sh
forge script script/VerifyPancakeDeployment.s.sol:VerifyPancakeDeployment \
  --rpc-url "$RPC_URL" \
  -vvvv
```

The verifier checks:

- required deployed contracts and external Pancake contracts have code
- MasterChefV3 CAKE and NPM pointers match the configured chain
- vault asset, oracle reference token, and Chainlink reference token match env config
- vault points to the deployed oracle and interest model
- `V3Vault.gaugeManager()` is the deployed `PancakeStakingManager` when enabled
- helper contracts use the expected Pancake NPM/factory/router settings
- V3Utils, LeverageTransformer, and AutoRange are allowlisted by the vault and know the vault
- AutoRange and AutoExit operator/withdrawer settings match env config
- staking manager MasterChef, CAKE, vault, and withdrawer settings match env config
- ownership is accepted or pending for `OWNER`
- oracle tokens, collateral tokens, reward routes, and MasterChef staking pools are configured

## 7. Final Smoke Checks

Before opening public access:

```sh
forge build
forge test --no-match-path 'test/integration/uniswap/**' -vv
forge test --match-path test/integration/base/PancakeBaseFork.t.sol -vv
forge test --match-path test/integration/bsc/PancakeBscFork.t.sol -vv
```

For BSC, run the deployment dry-run and verification script against a BSC RPC in addition to the fork smoke suite.

## Open Launch Inputs

The repo is ready to encode the final deployment once these decisions are made:

- First launch chain: Base, BSC, or both.
- Final multisig/owner, operator, withdrawer, staking withdrawer, and emergency admin addresses.
- Initial market risk parameters and launch caps.
- Whether to configure Base sequencer uptime feed at launch.
- Whether external router swap paths are enabled at launch, and the exact router/allowance-holder addresses.
- Initial supported LP pool list if it should be broader than the default templates.
