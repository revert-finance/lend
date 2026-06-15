# Revert Pancake V3 Automators

This branch contains PancakeSwap V3 utility, MasterChef staker, and automator contracts.

It intentionally removes the lending/vault system from the main branch. Pancake positions are handled either as owner-held Pancake V3 NFTs or as NFTs staked through `PancakeMasterChefV3Staker`.

## Setup

Install Foundry:

```sh
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Install dependencies:

```sh
forge install
```

## PancakeSwap V3 Compatibility

PancakeSwap V3 is Uniswap V3-like, but there are integration differences that matter for this branch:

- Pancake pools are resolved with `factory.getPool(tokenA, tokenB, fee)`.
- Do not rely on `PoolAddress.computeAddress` for Pancake pool discovery in project code, because vendored Uniswap periphery code contains Uniswap's `POOL_INIT_CODE_HASH`.
- Do not patch `lib/v3-periphery/contracts/libraries/PoolAddress.sol` in this branch just to change `POOL_INIT_CODE_HASH`; project contracts avoid that library path.
- If new Pancake-facing code needs a pool address, use the inherited `_getPool(tokenA, tokenB, fee)` helper or validate a supplied pool against `factory.getPool`.
- Pancake pools call `pancakeV3SwapCallback`, not `uniswapV3SwapCallback`; `Swapper` implements the Pancake callback and validates the caller against the canonical factory pool.
- Pancake `slot0()` has a different `feeProtocol` ABI width on some deployments. `_getPoolSlot0` uses a low-level decoder and only consumes `sqrtPriceX96` and `tick`.

The practical replacement for older `POOL_INIT_CODE_HASH` / `PoolAddress.computeAddress` style integrations is:

```solidity
address pool = factory.getPool(token0, token1, fee);
```

Reward-compound routes are configured on `PancakeMasterChefV3Staker` with canonical CAKE/base-token pools. Operators do not pass anchor or reward pool calldata.

## Contracts

The Pancake deployment script deploys:

- `V3Utils`: owner-facing position utility transformer.
- `AutoRangeAndCompound`: operator range adjustment, fee compound, and optional CAKE reward compound for owner-held or staker-held positions.
- `AutoExit`: operator exit/limit/stop execution for owner-held or staker-held positions.
- `PancakeMasterChefV3Staker`: custody contract that stakes Pancake V3 NFTs into MasterChefV3 and records logical owners.

## Staked Position Flow

MasterChefV3 gates `harvest`, `withdraw`, `collect`, and liquidity-changing actions by its recorded `user`. For an automator to operate a staked position, the staker contract must be that recorded user.

Flow:

- NFT owner approves `PancakeMasterChefV3Staker`.
- Owner calls `stakePosition(tokenId, recipient)`, or safe-transfers the NFT to the staker with ABI-encoded recipient data.
- The staker transfers the NFT into MasterChefV3.
- MasterChefV3 records the staker as `positionInfo.user`.
- The staker records the logical owner in `positionOwners[tokenId]`.
- Owner can call `claimRewards(tokenId, recipient)` or `unstakePosition(tokenId, recipient)`.
- Owner can approve an automator with `approveTransform(tokenId, automator, true)`.
- Operators call Pancake-aware automator entrypoints, such as `executeWithPancakeStaker`.

For non-staked owner-held NFTs, owners approve the automator directly in the Pancake V3 position manager and configure the position on the automator.

## CAKE Reward Compounding

There are two reward-compound patterns:

- Fee-only compounding uses normal `transform`.
- CAKE + fee compounding uses `transformWithRewardCompound`, so the staker harvests and compounds CAKE first, then runs the normal transform path and restakes non-empty results.

`PancakeMasterChefV3Staker` validates CAKE reward swaps with:

- Canonical Pancake factory pool checks.
- Current spot price vs TWAP checks.
- Minimum output derived from spot/TWAP tolerance.
- Fixed reward-swap limits: 60 second TWAP, 200 max tick difference, and 2% max price difference.
- Optional user-configured per-position minimums passed by `AutoRangeAndCompound`.

For reward routes:

- If the target token is CAKE, no swap is needed.
- If `rewardBasePools[target]` exists, CAKE swaps directly to the target token.
- Otherwise CAKE swaps to the other position token through `rewardBasePools[otherToken]`, then swaps through the position pool into the target token.

Reward-compound protocol fees stay in the staker and are withdrawable only by the staker `WITHDRAWER`.

## Tests

Unit tests run locally:

```sh
forge test --offline --match-path 'test/unit/**'
```

Fork smoke tests cover Pancake deployments on Ethereum mainnet, BSC, Arbitrum, and Base. Set the matching RPC URLs before running the full suite:

```sh
export MAINNET_RPC_URL=https://...
export BSC_RPC_URL=https://...
export ARBITRUM_RPC_URL=https://...
export BASE_RPC_URL=https://...

forge test
```

The fork smoke tests deploy the staker and `AutoRangeAndCompound` on forked chains and verify the configured MasterChef and CAKE setup. If `PANCAKE_REWARD_BASE_TOKENS` and `PANCAKE_REWARD_BASE_POOLS` are provided, the tests also assert that `setRewardBasePool` succeeds.

## Deployment

Use:

```sh
script/DeployPancakeV3UtilsAndAutomators.s.sol
```

Supported chains:

- `1` Ethereum mainnet
- `56` BSC
- `42161` Arbitrum
- `8453` Base

The script deploys all contracts, configures the Pancake staker in the transformers, allow-lists the transformers in the staker, optionally configures reward base pools, and initiates `Ownable2Step` ownership transfers.

### Default Addresses

Pancake and infra defaults:

- Pancake factory: `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865`
- Pancake V3 position manager: `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`
- Pancake V3 swap router: `0x1b81D678ffb9C0263b24A97847620C99d213eB14`
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3`
- 0x Allowance Holder: `0x0000000000001fF3684f28c67538d4D072C22734`

MasterChefV3 and CAKE defaults:

| Chain | MasterChefV3 | CAKE |
| --- | --- | --- |
| Ethereum | `0x556B9306565093C855AEA9AE92A594704c2Cd59e` | `0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898` |
| BSC | `0x556B9306565093C855AEA9AE92A594704c2Cd59e` | `0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82` |
| Arbitrum | `0x5e09ACf80C0296740eC5d6F643005a4ef8DaA694` | `0x1b896893dfc86bb67Cf57767298b9073D2c1bA2c` |
| Base | `0xC6A2Db661D5a5690172d8eB0a7DEA2d3008665A3` | `0x3055913c90Fcc1A6CE9a358911721eEb942013A1` |

Universal Router defaults:

| Chain | Universal Router |
| --- | --- |
| Ethereum | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` |
| BSC | `0x1906c1d672b88cD1B9aC7593301cA990F94Eae07` |
| Arbitrum | `0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3` |
| Base | `0x6fF5693b99212Da76ad316178A184AB56D299b43` |

Default roles:

- Owner:
  - Ethereum: `0xaac25e85e752425Dd1A92674CEeAF603758D3124`
  - Arbitrum: `0x3e456ED2793988dc08f1482371b50bA2bC518175`
  - Base: `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9`
  - BSC: deployer by default unless `OWNER` is set
- Operator: `0xae886c189a289be69Fb0249F2F0793d7B1E51ceB`
- Withdrawer: `0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82`

### Environment Overrides

```sh
export PANCAKE_NPM=0x...
export PANCAKE_MASTER_CHEF_V3=0x...
export CAKE=0x...
export UNIVERSAL_ROUTER=0x...
export ZEROX_ALLOWANCE_HOLDER=0x...
export PERMIT2=0x...

export OWNER=0x...
export OPERATOR=0x...
export WITHDRAWER=0x...

export TWAP_SECONDS=60
export MAX_TWAP_TICK_DIFFERENCE=100

export PANCAKE_REWARD_BASE_TOKENS=0xBaseTokenA,0xBaseTokenB
export PANCAKE_REWARD_BASE_POOLS=0xCakeBasePoolA,0xCakeBasePoolB
```

There is no deployment-time `POOL_INIT_CODE_HASH` override. Position pools are derived from the NFT's token pair and fee through `factory.getPool`. Reward base pools are optional and validated on-chain against the Pancake factory.

### Dry Run

```sh
PRIVATE_KEY=0xyour_private_key \
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$MAINNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  -vvvv
```

### Broadcast

Ethereum mainnet:

```sh
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$MAINNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

BSC:

```sh
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$BSC_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

Arbitrum:

```sh
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$ARBITRUM_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

Base:

```sh
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

After broadcast, the configured owner must call `acceptOwnership()` on each deployed `Ownable2Step` contract.

## Post-Deploy Checklist

- Verify deployed bytecode/source for `V3Utils`, `AutoRangeAndCompound`, `AutoExit`, and `PancakeMasterChefV3Staker`.
- Confirm `setPancakeStaker(staker)` is active on `V3Utils`, `AutoRangeAndCompound`, and `AutoExit`.
- Confirm `setTransformer(transformer, true)` is active on the staker for each allowed transformer.
- Confirm optional `setRewardBasePool(baseToken, pool)` entries are configured on the staker.
- Confirm `OWNER` has accepted ownership.
- Confirm `OPERATOR` and `WITHDRAWER` are correct.
- For staked positions, owners must call `approveTransform(tokenId, automator, true)` before operator execution.
- For owner-held positions, owners must approve the automator in the Pancake V3 position manager and configure the token on the automator.

## Operator Notes

- `AutoRangeAndCompound.executeWithPancakeStaker` changes range for staked positions.
- `AutoRangeAndCompound.executeWithPancakeStakerAndRewardCompound` compounds CAKE first, then changes range.
- `AutoRangeAndCompound.autoCompoundWithPancakeStaker` fee-compounds staked positions.
- `AutoRangeAndCompound.autoCompoundWithPancakeStakerAndRewardCompound` compounds CAKE first, then fee-compounds.
- `AutoExit.executeWithPancakeStaker` exits staked positions.
- Direct `execute` / `autoCompound` methods support owner-held positions where the automator is approved by the NFT owner.

## Safety Notes

- MasterChef-staked positions cannot be operated safely by a random third-party contract unless that contract is MasterChefV3's recorded `user`.
- The staker is designed to be the MasterChefV3 `user`; the human/user wallet remains the logical owner in staker accounting.
- Non-empty positions received by the staker during transforms are restaked.
- Empty residual positions remain withdrawable by the logical owner through `unstakePosition`.
- Fee-compound protocol rewards stay in `AutoRangeAndCompound`; reward-compound protocol rewards stay in the staker. Both can be withdrawn only by their configured `WITHDRAWER`.
