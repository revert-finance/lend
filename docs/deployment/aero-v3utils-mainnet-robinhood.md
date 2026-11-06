# Standalone Aero V3Utils: Ethereum and Robinhood

Prepared 2026-11-05 against `aero` source commit
`aa068839274bffbf0bcc83e9c2c694a1e978d6f8`. No `src/` contract changes.
This deploys V3Utils only. No vault, GaugeManager, automation contract or Poolside
factory is deployed; no vault is allowlisted. Each chain gets its own utility.

## Inputs and evidence

| Chain | Dependency | Address |
| --- | --- | --- |
| Ethereum | Aero NPM | `0x4857DB576eE0e45F10525eC59527BfD10beeC60b` |
| Ethereum | Aero factory | `0xf4fd2e6c5b60c5b365cd1b96dd6245e6d60414c2` |
| Ethereum | Wrapped ETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` |
| Ethereum | Universal Router | `0x66a9893cc07d91d95644aedd05d03f95e1dba8af` |
| Ethereum | 0x AllowanceHolder | `0x0000000000001ff3684f28c67538d4d072c22734` |
| Ethereum | Approved final owner | `0xaac25e85e752425dd1a92674ceeaf603758d3124` |
| Robinhood | Aero NPM | `0x4857DB576eE0e45F10525eC59527BfD10beeC60b` |
| Robinhood | Aero factory | `0xc63d7338c178e805c544b8f897066bd3bbcbe136` |
| Robinhood | Wrapped ETH | `0x0bd7d308f8e1639fab988df18a8011f41eacad73` |
| Robinhood | Universal Router | `0x8876789976decbfcbbbe364623c63652db8c0904` |
| Robinhood | 0x AllowanceHolder | `0x0000000000001ff3684f28c67538d4d072c22734` |
| Robinhood | Approved final owner | `0x8cadb20a4811f363dadb863a190708bed26245f8` |

Aero documents the shared NPM in its [official security page](https://app.aero.xyz/docs/security/).
Factories and wrapped ETH were independently read from that NPM on each chain.
Router and allowance-holder choices match the existing Revert V3Utils deployment
on each chain (Ethereum `0xab52f8c11e72d00d4f717a657378ef9b8bf7c2b6`, Robinhood
`0x98ec492942090364ac0736ef1a741ae6c92ec790`); bytecode existence was checked.
Do not confuse Aero's `SwapRouter` with the Universal Router's `execute` interface.
[0x contract documentation](https://docs.0x.org/docs/core-concepts/contracts) explains the AllowanceHolder entry point.
Robinhood chain ID 4663, ETH gas and Blockscout verification are documented in
[Robinhood's deployment guide](https://docs.robinhood.com/chain/deploy-smart-contracts/).
Ethereum chain ID is 1.

## Deployment

Use the local Foundry account `deployer`:
`0x83681C14770b44361e21Faf91D8325423365eA5C`.
Do not share its nonce stream with running bots on the chain being deployed.
Passwords are entered interactively; never put them in these scripts or docs.

From the repository checkout containing this script:

```sh
# The wrapper selects the approved owner for each chain automatically.
# Set MAINNET_RPC_URL / ROBINHOOD_RPC_URL, or use the existing ALCHEMY_API_KEY.
# Robinhood also defaults to https://rpc.mainnet.chain.robinhood.com.
bash script/deploy-aero-v3utils-multichain.sh mainnet --dry-run
bash script/deploy-aero-v3utils-multichain.sh mainnet --broadcast
bash script/deploy-aero-v3utils-multichain.sh mainnet --verify

# Robinhood uses its own approved owner automatically:
bash script/deploy-aero-v3utils-multichain.sh robinhood --dry-run
bash script/deploy-aero-v3utils-multichain.sh robinhood --broadcast
bash script/deploy-aero-v3utils-multichain.sh robinhood --verify
```

Ethereum verification requires `ETHERSCAN_API_KEY`; Robinhood uses Blockscout.
Dependencies should be installed with `git submodule update --init --recursive`
in a fresh checkout. Keep the compiler version/settings fixed through verification.

The script nominates the requested owner using Ownable2Step; the deployer remains
owner until that address calls `acceptOwnership()` on the new V3Utils. If it is a
Safe, submit a zero-value call to the utility with calldata `0x79ba5097` from that
Safe on the correct chain. Never send that acceptance from the deployer instead.

Broadcast refuses to overwrite an existing deployment record. If interrupted,
inspect actual receipts and pending nonces, then use `--resume` with the same
chain/owner. Do not start a fresh deployment blindly. Dry-run predictions are
not deployed addresses. Saved records live under
`broadcast/DeployAeroV3UtilsMultichain.s.sol/<chain-id>/run-latest.json`.

## Validation and limits

Deployment dry-runs passed at Ethereum block 26351200 and Robinhood block 107040000,
using the existing chain owners, now confirmed by the user. Estimated costs:
Ethereum 0.0023474 ETH; Robinhood 0.00021986 ETH (prices change). Runtime bytecode:
16,351 bytes, below the 24,576-byte EVM limit. The wrapper pins the confirmed owners per chain, overriding any stale owner
environment variable. No production transaction has been signed by this preparation.

Four fork tests passed on each chain (eight total).
Fork tests exercise wrong-chain and mismatched-factory rejection before deployment,
two-step ownership, Aero position
minting and full token withdrawal on WETH/USDC (Ethereum) and WETH/USDG (Robinhood).
Fork-only fixture funding impersonates the live pool to transfer tokens to the test user,
avoiding unsupported storage overrides on Robinhood. These tests do not establish future 0x quote liquidity or full frontend integration.

```sh
forge test --match-contract AeroV3UtilsMultichainTest --fork-url "$MAINNET_RPC_URL" --fork-block-number 26351200 -vv
forge test --match-contract AeroV3UtilsMultichainTest --fork-url "$ROBINHOOD_RPC_URL" --fork-block-number 107040000 -vv
```

After successful broadcasts: record actual addresses, creation transactions,
blocks, source-verification and ownership status in Revert's deployment docs.
Then integrate each network's Aero NPM/factory/utility and quote routing where
supported, plus backend executor and points registration. Existing Base addresses
and legacy Aerodrome deployments are unrelated and must stay intact. Deploying
these utilities alone does not enable Aero on either network in the application.
