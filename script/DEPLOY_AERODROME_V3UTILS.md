# Aerodrome V3Utils deployments (new CL factories)

Aerodrome has three Slipstream CL deployments on Base (see `aerodrome-finance/slipstream`,
`script/constants/output/`). `V3Utils` binds to one NonfungiblePositionManager at construction
(`Swapper` sets `factory = npm.factory()`), so each CL factory needs its own instance.

## Deployed

| Aerodrome CL deployment | PoolFactory | NonfungiblePositionManager | V3Utils | Deployed |
| --- | --- | --- | --- | --- |
| Original (`DeployCL-Base`) | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` | `0x827922686190790b37229fd06084350E74485b72` | see protocol deploy (vault-wired) | 2026-06-03 |
| Gauge-Caps (`DeployCL-Base-Gauge-Caps`) | `0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a` | `0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F` | **`0x93a8F1FFAae10e3E5B67a0F36aB9581bCDc463C7`** | 2026-08-02, block 49450662 |
| MinUnstake (`DeployCL-Base-MinUnstake`) | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | **`0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD`** | 2026-08-02, block 49450914 |

Transactions: Gauge-Caps `0x9e9f2f70f20b6d326bde896a2fbf9b7f2119cdcbe3eb596009b70bc255099589`,
MinUnstake `0x3b929c245ed5875ecb224f7f7470f67b2287af04fabf574aecec34651ca89482`.
Cost ~0.0000178 ETH each (3,561,014 gas at ~0.005 gwei). Both 16,071 bytes of code.

Verified on-chain after deployment — each instance resolves its own factory and NPM:

```
                            Gauge-Caps                                  MinUnstake
nonfungiblePositionManager  0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F  0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53
factory                     0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a  0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef
universalRouter             0x6Cb442acF35158D5eDa88fe602221b67B400Be3E  0x6Cb442acF35158D5eDa88fe602221b67B400Be3E
weth                        0x4200000000000000000000000000000000000006  0x4200000000000000000000000000000000000006
owner                       0x83681C14770b44361e21Faf91D8325423365eA5C  0x83681C14770b44361e21Faf91D8325423365eA5C
```

## OPEN ITEM: ownership sits on a hot automation key

Both contracts are owned by **`0x83681C14770b44361e21Faf91D8325423365eA5C`**, which is what the
forge keystore account `deployer` resolves to. That address is **not** either historical deployer
EOA (`0x8df57e3d…`, `0x3895e33b…`) — it is a high-frequency automation bot (nonce >1,129,000 on
Base, 27,000+ on mainnet, 291,000+ on Arbitrum) that continuously signs `execute` /
`executeWithVault` calls. The owner controls `setVault()` and the stuck-token withdrawal path.

Nothing is at risk today (no funds held, no vault wired), but consider transferring to the Base
multisig, matching `DeployAerodromeProtocol`. `V3Utils` inherits `Ownable2Step` (via `Transformer`),
so the transfer is **two steps from two accounts**: the current owner proposes, then the multisig
must call `acceptOwnership()` itself — until it does, the hot key remains the owner.

```sh
# step 1 — current owner proposes (sets pendingOwner only)
cast send 0x93a8F1FFAae10e3E5B67a0F36aB9581bCDc463C7 "transferOwnership(address)" \
  0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9 --rpc-url "$BASE_RPC_URL" --account deployer
cast send 0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD "transferOwnership(address)" \
  0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9 --rpc-url "$BASE_RPC_URL" --account deployer

# step 2 — Safe transaction from 0x45B220…1cc9, one per contract:
#   to   = <V3Utils address>,  value = 0,  data = acceptOwnership()  (0x79ba5097)
cast calldata "acceptOwnership()"

# verify: owner() == Safe and pendingOwner() == 0x0
cast call 0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD "owner()(address)" --rpc-url "$BASE_RPC_URL"
cast call 0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD "pendingOwner()(address)" --rpc-url "$BASE_RPC_URL"
```

As of 2026-09-16 neither contract has a pending owner (`pendingOwner() == 0x0`); nothing has been
proposed yet.

## Scope

These are standalone utility contracts for positions on the new factories: swap-and-mint, range
changes, compound fees, withdraw-and-swap. They are **not** wired to a vault and cannot be — the
live `rlAeroUSDC` vault (`0x1ef7c181188687e20a9750714f1b9de6f70f17c0`) is bound to the original
NPM, and a `V3Utils` on a different NPM cannot serve it.

Swaps route through the Aerodrome `UniversalRouter` (`0x6Cb442ac…`) or the 0x AllowanceHolder.
`Swapper._routerSwap` only understands those two ABIs, so a per-factory plain `SwapRouter`
(`0xcbBb8035…`, `0x698Cb2b6…`) must **not** be passed as `_universalRouter` — swaps would revert.
Note the UniversalRouter is pinned to the *original* CL factory plus Aerodrome v2, so the swap leg
executes in those pools, never inside the new factories' pools. That matches the behaviour of the
existing live V3Utils and is not a regression; where a pair's liquidity sits only in a new-factory
pool, the 0x path covers it.

## Re-running

```sh
export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

forge script script/DeployBaseV3UtilsNewClFactory.s.sol:DeployBaseV3UtilsNewClFactory \
  --rpc-url "$BASE_RPC_URL" --account deployer --broadcast -vvvv

forge script script/DeployBaseV3UtilsMinUnstakeFactory.s.sol:DeployBaseV3UtilsMinUnstakeFactory \
  --rpc-url "$BASE_RPC_URL" --account deployer --broadcast -vvvv
```

Both scripts take the signer from the CLI — no `PRIVATE_KEY` needed. Add
`--verify --etherscan-api-key $ETHERSCAN_API_KEY` to verify on Basescan. Both validate chain id,
contract code, the NPM↔factory linkage, `npm.WETH9()`, and three live pools before broadcasting.

Design spec: `docs/superpowers/specs/2026-07-31-aerodrome-v3utils-new-factories-design.md`.
