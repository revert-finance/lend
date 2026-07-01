# AutoRange Fix Deployment

This runbook is for the fixed Uniswap V3 `AutoRange` transformer only.
Aerodrome is intentionally excluded and should be handled on its own branch.

## Deployments

| Chain | Vault | Old AutoRange |
| --- | --- | --- |
| Ethereum mainnet | `0xa2754543f69dC036764bBfad16d2A74F5cD15667` | `0x88481E2Fbc98d4a251655B0F1A4422555EA72d9E` |
| Arbitrum | `0x74E6AFeF5705BEb126C6d3Bf46f8fad8F3e07825` | `0x5ff2195BA28d2544AeD91e30e5f74B87d4F158dE` |
| Base | `0x36AEAe0E411a1E28372e0d66f02E57744EbE7599` | `0xA8549424B20a514Eb9e7a829ec013065Bef9Dc1D` |

The script deploys a new `AutoRange`, calls `setVault(vault)` on it, and transfers ownership to the existing chain owner. It does not call `vault.setTransformer`; the vault owner/multisig must do that after review.

By default, the script uses `address(0)` for `OPERATOR` so the new transformer is deployed without an active bot. The export blocks below set the current operator bot explicitly.

The operator bot address is currently disabled on the old `AutoRange` deployments. Exporting `OPERATOR` below enables that bot in the new fixed deployment constructor.

## Vault Owners

These are the current live `vault.owner()` addresses that must whitelist the new transformer.

| Chain | Vault owner |
| --- | --- |
| Ethereum mainnet | `0xaac25e85e752425Dd1A92674CEeAF603758D3124` |
| Arbitrum | `0x199B7d994c9d3A26ff81E93bdB5dBc780363F330` |
| Base | `0x36bF9981bA905cA63Bdd3271775DB43CC57eB1CF` |

## Commands

```sh
forge script script/DeployAutoRangeFix.s.sol:DeployAutoRangeFix \
  --rpc-url "$MAINNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

```sh
forge script script/DeployAutoRangeFix.s.sol:DeployAutoRangeFix \
  --rpc-url "$ARBITRUM_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

```sh
forge script script/DeployAutoRangeFix.s.sol:DeployAutoRangeFix \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

## Environment

### Ethereum Mainnet

```sh
export OWNER=0xaac25e85e752425Dd1A92674CEeAF603758D3124
export OPERATOR=0xbb1a1a2773a799d83078ae4d59d9f4b2b6ac50ff
export WITHDRAWER=0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82
export UNIVERSAL_ROUTER=0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD
export ZEROX_ALLOWANCE_HOLDER=0x0000000000001fF3684f28c67538d4D072C22734
export TWAP_SECONDS=60
export MAX_TWAP_TICK_DIFFERENCE=100
```

### Arbitrum

```sh
export OWNER=0x3e456ED2793988dc08f1482371b50bA2bC518175
export OPERATOR=0xbb1a1a2773a799d83078ae4d59d9f4b2b6ac50ff
export WITHDRAWER=0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82
export UNIVERSAL_ROUTER=0x5E325eDA8064b456f4781070C0738d849c824258
export ZEROX_ALLOWANCE_HOLDER=0x0000000000001fF3684f28c67538d4D072C22734
export TWAP_SECONDS=60
export MAX_TWAP_TICK_DIFFERENCE=100
```

### Base

```sh
export OWNER=0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9
export OPERATOR=0xbb1a1a2773a799d83078ae4d59d9f4b2b6ac50ff
export WITHDRAWER=0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82
export UNIVERSAL_ROUTER=0xeC8B0F7Ffe3ae75d7FfAb09429e3675bb63503e4
export ZEROX_ALLOWANCE_HOLDER=0x0000000000001fF3684f28c67538d4D072C22734
export TWAP_SECONDS=60
export MAX_TWAP_TICK_DIFFERENCE=100
```

## Post-Deploy Actions

1. If ownership was transferred, the new `AutoRange` owner calls `acceptOwnership()`.
2. The vault owner/multisig calls `setTransformer(newAutoRange, true)`.
3. The vault owner/multisig should call `setTransformer(oldAutoRange, false)` after migration.
4. If `OPERATOR` was left unset, the new `AutoRange` owner calls `setOperator(bot, true)` only after the vault allowlist step is complete.

The script prints calldata for steps 1-3 after deployment.
