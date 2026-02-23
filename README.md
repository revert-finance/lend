# Revert Lend

This repository contains the smart contracts for Revert Lend protocol.

It uses Foundry as development toolchain.


## Setup

Install foundry 

https://book.getfoundry.sh/getting-started/installation

Install dependencies

```sh
forge install
```


## Tests

Most tests use a forked state of Ethereum Mainnet. You can run all tests with: 

```sh
forge test
```


Because the v3-periphery library (Solidity v0.8 branch) in lib/v3-periphery/contracts/libraries/PoolAddress.sol has a different POOL_INIT_CODE_HASH than the one deployed on Mainnet this needs to be changed for the integration tests to work properly and for deployment!

bytes32 internal constant POOL_INIT_CODE_HASH = 0xa598dd2fba360510c5a8f02f44423a4468e902df5857dbce3ca162a43a3a31ff;

needs to be changed to 

bytes32 internal constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

## Deployment for PancakeSwap (V3Utils + Automators)

This repo includes `script/DeployPancakeV3UtilsAndAutomators.s.sol`, based on the PancakeSwap deployment flow from `v3utils`.

It deploys:
- `V3Utils`
- `AutoRange`
- `AutoCompound`
- `AutoExit`

Supported chains:
- `1` (Ethereum mainnet)
- `42161` (Arbitrum)
- `8453` (Base)

### Defaults used by the script

The script has built-in defaults for Pancake and infra addresses:
- Pancake NPM: `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3`
- 0x Allowance Holder: `0x0000000000001fF3684f28c67538d4D072C22734`
- Universal Router:
  - Mainnet: `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`
  - Arbitrum: `0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3`
  - Base: `0x6fF5693b99212Da76ad316178A184AB56D299b43`

Built-in role defaults:
- Owner:
  - Mainnet: `0xaac25e85e752425Dd1A92674CEeAF603758D3124`
  - Arbitrum: `0x3e456ED2793988dc08f1482371b50bA2bC518175`
  - Base: `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9`
- Operator: `0xae886c189a289be69Fb0249F2F0793d7B1E51ceB`
- Withdrawer: `0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82`

`OWNER`, `OPERATOR`, and `WITHDRAWER` can still be overridden via env vars.

### Optional overrides

```sh
export PANCAKE_NPM=0x...
export UNIVERSAL_ROUTER=0x...
export ZEROX_ALLOWANCE_HOLDER=0x...
export PERMIT2=0x...

export OWNER=0x...
export OPERATOR=0x...
export WITHDRAWER=0x...

export TWAP_SECONDS=60
export MAX_TWAP_TICK_DIFFERENCE=100
```

### Dry run (Ethereum mainnet)

```sh
ETH_RPC_URL="https://..." \
PRIVATE_KEY="0xyour_private_key" \
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$ETH_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  -vvvv
```

### Broadcast

```sh
# Ethereum mainnet
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$MAINNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv

# Arbitrum
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$ARBITRUM_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv

# Base
forge script script/DeployPancakeV3UtilsAndAutomators.s.sol:DeployPancakeV3UtilsAndAutomators \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

After broadcast, ownership transfer is initiated for all deployed `Ownable2Step` contracts.  
The configured owner must call `acceptOwnership()` on each deployed contract.
