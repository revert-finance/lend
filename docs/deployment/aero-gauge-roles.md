# Restricted Aero gauge registration through the Base Safe

This adds a dedicated operator for **first-time** gauge registrations on the current
Base deployment. It does not change or redeploy the lending contracts. The Safe
remains owner of the vault and GaugeManager. Deployment and Safe activation are
separate; this PR does not execute either or install a scheduled job.

## Authority and checks

| Component | Pinned address / responsibility |
| --- | --- |
| Base Safe | `0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9`, owns the manager and Roles instance |
| GaugeManager | `0xeF1367c2B487233315fE14909A738C7517a41beD`, sole allowed execution target |
| Vault | `0x4A315e98D87c049B92e31A677a4DeC63f4eF8F7f`, ownership and configuration unchanged |
| Aero CL factory | `0x9CB220581b91b0C83223012FE69688b92aD07a76` |
| Registry | `0x7b2A2c12dC5Ea2a31455952a05031C3E4BB28F3E` |
| Gauge factory | `0xf437f62053ACB121665b8fDBfeA8F214FB8E589d` |
| Voter | `0x382409fad8503FbCdbB27A4211551fa03e884078` |
| NPM | `0x4857DB576eE0e45F10525eC59527BfD10beeC60b` |
| Root handler | `0x8C37F30F3c8fd48bEddb14086fa5148291D422C3` |

The operator calls `execTransactionWithRole` on a new Roles instance. Roles checks
its membership, target, selector, zero value, ordinary CALL operation, and the
custom condition before the Safe calls `GaugeManager.setGauge(pool,gauge)`.
The Safe signs the setup once; each subsequent eligible registration needs only
the dedicated operator's transaction.

The immutable condition checks at **execution time**:

- No existing manager mapping for the pool. Neither clearing nor replacing is allowed.
- The pinned factory resolves the pool from its token pair and tick spacing.
- The pinned registry approves that factory and maps the pool to the supplied gauge
  and the factory to the expected gauge factory.
- Pool/gauge/NPM/voter/gauge-factory bindings match; the official voter reports the
  gauge activated; existing `AeroRewardDelivery.validate` accepts its reward binding.
- Exact `setGauge(address,address)` calldata, with no trailing bytes. Only this
  Roles instance can invoke the condition successfully.

A token symbol, a gauge's self-reported factory, or an off-chain discovery result
alone cannot authorize registration. Bad dependency reads fail closed. Official
Aero factory/registry/voter/reward administration remains trusted. Gauge registration
does **not** approve collateral, change oracle settings, list a pool in Poolside,
guarantee liquidity/token safety, or migrate an already-staked position.

The operator may register any qualifying pool, even one not in a product catalog.
It cannot change existing mappings, ownership, fees, rewards routes, withdrawal
recipients, Safe modules, or Roles permissions. Manual replacements still use the
existing `sync-aero-gauges.sh --safe` flow. The Safe can change or revoke the role.

## Zodiac dependency

Use **Roles 2.1.1**, not 2.1.0:

| Dependency | Address |
| --- | --- |
| Roles implementation | `0xF2964CE6161ce0e75964Fe7927cE114cb0B283D5` |
| Integrity library | `0x6a6Af4b16458Bc39817e4019fB02BD3b26d41049` |
| Packer library | `0x869718C939652084BC491fBC5ce0D3C1d5B309F0` |
| ModuleProxyFactory 1.2.0 | `0x000000000000aDdB49795b0f9bA5BC298cDda236` |

Deployment and sync pin the runtime hashes of all four, plus the exact proxy
runtime and its owner/avatar/target. Base bytecode was compared to the
[published artifacts at commit b7988c0](https://github.com/zodiaceco/zodiac/tree/b7988c0e352c8e409145b76d193ba67a6f2e44d1/mastercopies).
The [Zodiac post-mortem](https://engineering.gnosisguild.org/posts/zodiac-post-mortem)
and [security documentation](https://docs.zodiac.eco/developers/security) identify
2.1.1 as the patched release for the ERC-1271 issue. The June 2026 patch review is
not an audit of this integration or the entire module. Hash matching establishes
artifact identity, not absence of defects; no independent recompilation of the
upstream 0.8.21 artifacts is claimed.

A Safe module has execution authority at the Safe boundary. Its security therefore
depends on Roles and this exact restricted configuration. This design uses a new
instance, one dedicated EOA, one target, one selector, and no default role, wildcard
permissions, unwrappers or delegatecalls. Do not reuse an instance with other roles.
See [the dependency evidence](aero-gauge-roles-dependencies.json).

## Deployment and Safe setup

Choose a **dedicated registration EOA**, separate from the deployment signer and
existing automation signers. Fund it only for gas. Keep its keystore/password in
the job's secret environment, never in repository files. The scripts do not create
or export keys. RPC uses `BASE_RPC_URL`, falling back to `ALCHEMY_API_KEY`.

```bash
export AERO_GAUGE_DEPLOYER=0x83681C14770b44361e21Faf91D8325423365eA5C
export AERO_GAUGE_DEPLOYER_ACCOUNT=deployer
export AERO_GAUGE_OPERATOR=<dedicated-public-address>
export AERO_GAUGE_ROLES_SALT=<fresh-numeric-salt>
bash script/deploy-aero-gauge-roles.sh --dry-run
# Only after reviewing the rehearsal, with shared deployment-signer bots paused:
bash script/deploy-aero-gauge-roles.sh --broadcast
```

This sends two transactions: deploy/initialize the Roles proxy atomically through
the official factory, then deploy the condition. Both owner/avatar/target of Roles
are the Safe from initialization. No module is enabled and no role is granted by
the deployer. A partial deployment cannot execute through the Safe. If interrupted,
inspect both receipts and signer pending nonce before `--resume`; keep the same
salt and inputs and do not start another fresh broadcast blindly.

The script prints `ROLES`, `CONDITION` and `SAFE_SETUP` and writes:

- `gauge-sync/roles-<address>/deployment.json`: role key and public addresses.
- `gauge-sync/roles-<address>/setup.json`: Safe Transaction Builder batch.

Dry-run addresses are **predictions**, not deployment records. Before accepting a
batch, reconcile both addresses with successful receipts and verify the condition
source and immutable Roles binding. Do not use an earlier rehearsal's JSON after
nonce changes. Publish condition source from this exact checkout with:

```bash
forge verify-contract "$AERO_GAUGE_CONDITION" \
  src/permissions/AeroGaugeRegistrationCondition.sol:AeroGaugeRegistrationCondition \
  --chain 8453 --constructor-args "$(cast abi-encode 'constructor(address)' "$AERO_GAUGE_ROLES")" \
  --watch
```

Provide `ETHERSCAN_API_KEY` through the environment. The Roles implementation is
upstream; verify its proxy runtime and implementation as described above.

Import the **actual deployment's** `setup.json` into the Base Safe Transaction
Builder and simulate the entire batch. Its four calls, in order, are:

1. Scope only the current GaugeManager target to function-level permissions.
2. Scope only `setGauge(address,address)` to the custom condition, options `0`.
3. Assign `keccak256("REVERT_AERO_REGISTER_NEW_GAUGE_V1")` to the dedicated EOA.
4. Enable the Roles instance on the Safe **last**.

All calls have zero value. Verify the operator, condition address, target, selector
and role in decoded calldata before signing. After execution check `owner()`,
`avatar()`, `target()`, `isModuleEnabled(roles)`, and run the restricted dry-run below.
Record successful deployment/setup transaction hashes and final addresses in the
production deployment inventory; this PR deliberately contains no proposed
addresses presented as live deployments.

## Periodic execution

```bash
export AERO_GAUGE_MANAGER=0xeF1367c2B487233315fE14909A738C7517a41beD
export AERO_GAUGE_ROLES=<actual-deployed-instance>
export AERO_GAUGE_CONDITION=<actual-deployed-condition>
export AERO_GAUGE_OPERATOR=<dedicated-public-address>
export AERO_GAUGE_OPERATOR_ACCOUNT=<dedicated-foundry-keystore-name>
bash script/sync-aero-gauges.sh --roles-dry-run
bash script/sync-aero-gauges.sh --roles-broadcast
```

The existing discovery scan finds new gauges on both old and new pools. It skips
inactive/incompatible entries. Role mode preflights all first registrations against
the condition and logs replacements as `MANUAL_REPLACEMENT_POOL` without sending
them. Each registration revalidates on-chain. A race or deactivation can revert;
there is no privileged fallback. A partial run is recoverable by waiting for
pending transactions, rescanning, and rerunning: completed mappings are omitted.
Do not replay an old plan. `AERO_FORK_BLOCK` is rejected for broadcast.

Once activation and a manual run are verified, schedule the same command periodically
(e.g. every six hours), with a process lock to prevent concurrent runs using the
operator nonce. Use a keystore secret supplied through the deployment environment
(e.g. Foundry's `ETH_PASSWORD`); do not put it in a cron line. Monitor failures,
incompatible entries, replacements and operator gas balance. This PR provides the
command; installing an unattended signer or scheduled production service is a
separate operational step.

To stop registrations, the Safe calls Roles `assignRoles(operator,[roleKey],[false])`.
Alternatively disable the module on the Safe using `disableModule(previous,roles)`;
find its **current** predecessor with `getModulesPaginated`, not a stale guessed
pointer. Both revocations are tested. Stopping the job alone does not revoke a
compromised key. Existing gauge mappings and user positions remain intact.

## Validation

```bash
forge test --match-path 'test/permissions/*.t.sol' -vv
# Export BASE_RPC_URL with historical state support:
forge test --match-path test/fork/AeroGaugeRoles.t.sol -vv
```

The Base fork at block 59,778,757 executes the exact setup calls against the real
Safe, deployed Roles implementation/libraries, current GaugeManager and ANTc's
canonical gauge. Only Safe governance setup/revocation is impersonated; registration
runs as the dedicated operator. Tests cover registration, unchanged ownership,
replacement/repeat rejection, malformed/fake calls, activation races, authorization,
zero-value/CALL-only enforcement, both revocation routes and sync replacement skips.
Unit tests cover the additional registry/dependency failure cases.

Recorded validation on 2026-11-20: 20 unit tests, 11 new Base-fork tests and all
10 existing gauge-sync fork tests passed. The deployment wrapper dry-run succeeded
with two proposed transactions and an estimated 1,914,414 gas (including padding);
its generated JSON contained exactly four zero-value setup calls with module
enablement last. No transactions were broadcast.
