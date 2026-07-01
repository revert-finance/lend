# Aerodrome AutoRange Fix Deployment

This runbook is for the fixed Base Aerodrome `AutoRangeAndCompound` transformer only.

The script deploys a new `AutoRangeAndCompound`, calls `setVault(vault)` on it, and transfers ownership to the Base multisig. It does not call `vault.setTransformer`; the vault owner/multisig must do that after review.

By default, the script uses `address(0)` for `OPERATOR` so the new transformer is deployed without an active bot. The environment block below sets the current operator bot explicitly.

## Required Deployed Addresses

`VAULT` and `OLD_AUTO_RANGE` are required because the Aerodrome deployment addresses are not committed in this branch. Use the deployed Base Aerodrome vault and currently-whitelisted `AutoRangeAndCompound` addresses.

```sh
export VAULT=0x...
export OLD_AUTO_RANGE=0x...
```

## Base Environment

```sh
export OWNER=0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9
export OPERATOR=0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF
export WITHDRAWER=0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82
export AERODROME_SWAP_ROUTER=0x6Cb442acF35158D5eDa88fe602221b67B400Be3E
export ZEROX_ALLOWANCE_HOLDER=0x0000000000001fF3684f28c67538d4D072C22734
export TWAP_SECONDS=60
export MAX_TWAP_TICK_DIFFERENCE=100
```

The script also hardcodes and validates the Base Aerodrome NPM:

```sh
0x827922686190790b37229fd06084350E74485b72
```

## Command

```sh
forge script script/DeployAerodromeAutoRangeFix.s.sol:DeployAerodromeAutoRangeFix \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvvv
```

## Post-Deploy Actions

1. If ownership was transferred, the new `AutoRangeAndCompound` owner calls `acceptOwnership()`.
2. The vault owner/multisig calls `setTransformer(newAutoRange, true)`.
3. The vault owner/multisig should call `setTransformer(oldAutoRange, false)` after migration.
4. If `OPERATOR` was left unset, the new `AutoRangeAndCompound` owner calls `setOperator(bot, true)` only after the vault allowlist step is complete.

The script prints calldata for steps 1-3 after deployment.
