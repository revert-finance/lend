# Aerodrome V3Utils for the two new Slipstream factories — design

Date: 2026-07-31
Branch: `aerodrome-slipstream`
Status: approved (approach A)

## Goal

Deploy one standalone `V3Utils` per new Aerodrome Slipstream CL deployment on Base, signed with the forge keystore account `deployer` (`--account deployer`), from this branch.

Aerodrome has three CL deployments on Base (per `aerodrome-finance/slipstream` `script/constants/output/`, verified on-chain 2026-07-31):

| Deployment | PoolFactory | NonfungiblePositionManager | Positions | Revert V3Utils |
| --- | --- | --- | --- | --- |
| Original (`DeployCL-Base`) | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` | `0x827922686190790b37229fd06084350E74485b72` | 22.5M | live, vault-wired |
| Gauge-Caps (`DeployCL-Base-Gauge-Caps`) | `0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a` | `0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F` | 3.5M | **to deploy** |
| MinUnstake (`DeployCL-Base-MinUnstake`) | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | 1.0M | **to deploy** |

`V3Utils` binds to one NPM at construction (via `Swapper`), hence one contract per factory.

## Decisions (Mario, 2026-07-31)

1. **Scope**: both new factories (Gauge-Caps and MinUnstake).
2. **Ownership**: keep the deployer EOA as owner — no `transferOwnership` (matches the existing `DeployBaseV3UtilsNewClFactory` behavior).
3. **Swap router**: Aerodrome `UniversalRouter` `0x6Cb442acF35158D5eDa88fe602221b67B400Be3E` for both (matches the existing audited script and the live protocol V3Utils; swap venue does not need to match the position's factory since swap paths are built off-chain).
4. **Signing**: forge keystore account (`--account deployer`); scripts must not require `PRIVATE_KEY`.

## Changes

### 1. `script/DeployBaseV3UtilsNewClFactory.s.sol` (Gauge-Caps — existing, minimal edit)

Remove the `vm.envUint("PRIVATE_KEY");` guard (line 35). Bare `vm.startBroadcast()` takes the sender from the CLI (`--account deployer`). No other changes — constants, validation, and structure stay as audited.

### 2. `script/DeployBaseV3UtilsMinUnstakeFactory.s.sol` (new)

Clone of the Gauge-Caps script structure with MinUnstake constants:

- `AERODROME_NPM = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53`
- `AERODROME_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef`
- `AERODROME_SWAP_ROUTER = 0x6Cb442acF35158D5eDa88fe602221b67B400Be3E` (UniversalRouter)
- `ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734`
- Tokens: USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, WETH `0x4200000000000000000000000000000000000006`, CBBTC `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`
- Sanity pools (verified live, liquid, `nft()` == NPM):
  - WETH/USDC tickSpacing 1: `0x4e392fBfE4D0557C82D2F97F02ec39daA31516dd`
  - WETH/USDC tickSpacing 50: `0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A`
  - CBBTC/USDC tickSpacing 1: `0x9D14ff91AE2c6e3D1A760542248B6c7F206894b0`

Validation before broadcast (same shape as the existing script): chain id 8453; code exists at NPM, factory, router, allowance holder; `npm.factory() == AERODROME_FACTORY`; `npm.WETH9() == WETH`; per pool — factory `getPool` round-trip, token pair, tick spacing, `pool.factory()`, `pool.nft() == NPM`.

Broadcast: `new V3Utils(IAerodromeNonfungiblePositionManager(AERODROME_NPM), AERODROME_SWAP_ROUTER, ZEROX_ALLOWANCE_HOLDER)`; log the deployed address.

Note: the MinUnstake factory's CBBTC/WETH ts=50 pool exists in `getPool` but is uninitialized (`nft()` returns zero) — deliberately not used as a sanity pool.

## Out of scope

- No `setVault` / `vault.setTransformer` — the live vault (`rlAeroUSDC` `0x1ef7c181188687e20a9750714f1b9de6f70f17c0`) is bound to the v1 NPM; a V3Utils on a different NPM cannot serve it.
- No ownership transfer.
- No changes to `DeployAerodromeProtocol.s.sol` or `ConfigureV3Utils.s.sol`.

## Run commands

```sh
# dry run (validation executes fully, nothing broadcast)
forge script script/DeployBaseV3UtilsNewClFactory.s.sol:DeployBaseV3UtilsNewClFactory \
  --rpc-url "$BASE_RPC_URL" --account deployer -vvvv

forge script script/DeployBaseV3UtilsMinUnstakeFactory.s.sol:DeployBaseV3UtilsMinUnstakeFactory \
  --rpc-url "$BASE_RPC_URL" --account deployer -vvvv

# broadcast (append --verify --etherscan-api-key $ETHERSCAN_API_KEY to verify in the same step)
forge script <script> --rpc-url "$BASE_RPC_URL" --account deployer --broadcast -vvvv
```

Pre-flight: `cast wallet address --account deployer` (prompts for password) to confirm the signer, and check it holds ETH on Base for gas.

## Testing

- `forge build` compiles both scripts.
- Fork dry-run of both scripts against Base RPC — all `_validateDeploymentConfig` checks pass, deployment simulated.
- After broadcast: `nonfungiblePositionManager()`, `universalRouter()`, and `owner()` read back correctly on both new contracts.
