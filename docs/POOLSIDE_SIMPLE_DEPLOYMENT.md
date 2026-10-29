# Poolside Simple fee replacement

New deployments use `PoolsideFactory` and `PoolsidePosition`. Previously deployed
`PoolPeachFactory`/`PoolPeachPosition` contracts retain their original verified names.
The name change adds no new permissions or behavior.

Poolside holder creation must explicitly select `CompoundMode.Simple`. The previous
factory at `0xBD60864C0CD391667860f51D2a965BA28EA04519` creates holders that never select a
mode, so they use the Advanced rate (5%). The replacement sets Simple (currently 10%)
while retaining the previous zeroed range/standalone-compound configuration. The
staking-management path still compounds on custody changes. This is a fee-policy
correction, not a change to custody, withdrawal, rewards recovery or AutoExit rules.

Only the factory is deployed; it embeds the updated holder creation code. Existing
holders are immutable and are not upgraded. The old factory's AutoExit authorization
is retained so existing holders can still exit. Never route new users to the old
factory after switching Poolside. This integration belongs exclusively to Poolside,
not the Revert site.

The script reuses the verified 2026-10-29 Base contracts:

| Dependency | Address |
| --- | --- |
| V3Utils | `0xF3B5c0689df879Db47Fd23590700910e7a99A068` |
| Vault | `0x39125A0476D44C9EEC1F4206E9e8B1e88b4Aa730` |
| Automation | `0x5c94a69fFDC3Fcb2c3d6e08Ce033297Fb92aE800` |
| AutoExit | `0x9b23ba84C0B33c608db6a1c34Fc37BaA1F1A2C65` |

Run from this protocol checkout, using the existing local Foundry account `deployer`:

```bash
bash script/deploy-poolside-factory.sh --dry-run
bash script/deploy-poolside-factory.sh --broadcast
bash script/deploy-poolside-factory.sh --verify
```

Set `BASE_RPC_URL` or the existing `ALCHEMY_API_KEY`; verification also requires
`ETHERSCAN_API_KEY`. Enter the local keystore password interactively for broadcast.
Keep Base bots using this account paused throughout broadcast/resume. The two
transactions deploy the factory and grant it AutoExit operator permission. Preflight
requires Base, the 10% Simple rate, and deployer ownership of AutoExit. Complete this
before Safe ownership acceptance; if the Safe has accepted, the script stops before
broadcast and authorization needs a separately prepared Safe transaction.

If interrupted, inspect saved receipts before `--resume`. A failed authorization must
be repaired on the existing factory rather than deploying another blindly. Do not
resume a sequence whose nonce was consumed by another transaction. Record the actual
factory address from the successful receipt, confirm `AutoExit.operators(factory)`,
and give that address and verified source to the Poolside integration agent. No vault,
GaugeManager, automation redeployment, borrowing activation or ownership transfer is
part of this script. Source verification includes the holder source embedded in the
factory; individual holders are created later by users.

Validation: 63 fork tests passed: 47 holder tests at Base block 53255803 against
these existing contracts and 16 fresh protocol-deployment tests. Coverage includes
staked/unstaked creation selecting the 10% Simple rate, fee-mode authorization,
keeper staking, exit and deferred-reward regressions. The Safe handoff helper also
passed read-only checks with historical and renamed factory labels. The deployment
script dry-run passed against current Base state with exactly one CREATE and one
`setOperator` call. Factory runtime is 19,094 bytes and holder runtime is 10,038 bytes
(limit: 24,576). The verification helper's compiler input reproduced factory creation
bytecode exactly. No production transaction has been sent for this replacement.
