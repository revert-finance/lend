# Full Aero deployment and periodic gauge synchronization

Prepared from `aero` commit `efc74c0ca193a21868a94ca021ed1a6778d02cde` (the merged debt-free valuation fix).
This workflow is for the **new Aero CL factory on Base**, not legacy Aerodrome.
All changes are deployment/maintenance tooling; no `src/` contract logic changes.

## Scope and validation

Both full deployment and maintenance enumerate `allPools(0..allPoolsLength-1)` on
`0x9CB220581b91b0C83223012FE69688b92aD07a76`. Each run scans existing pools again,
so it finds new gauges on old pools and replacements, not just newly created pools.
The shared discovery helper validates canonical factory resolution, pool-to-gauge
binding, gauge-to-pool binding, NPM `0x4857DB576eE0e45F10525eC59527BfD10beeC60b`,
gauge factory `0xf437f62053ACB121665b8fDBfeA8F214FB8E589d`, supported local root
reward delivery, and LeafVoter `isActivated`. It does not use legacy Voter
`isAlive` or `isGauge` methods.

- Include every compatible activated gauge, irrespective of token symbol, TVL,
  current active liquidity, Poolside catalog membership or lending eligibility.
- Skip zero gauges, inactive gauges and incompatible bindings, with separate
  counts and logs identifying inactive/incompatible pools. Inspect nonzero
  `INCOMPATIBLE`; do not mistake it for successful registration of every pool.
- Factory enumeration/read errors abort, rather than pretending the inventory is empty.
- Maintenance requires an explicit manager address and verifies its NPM, factory,
  reward token and existing root-handler binding. It emits only changed/missing mappings.
- Never clear mappings because a gauge disappears or becomes inactive. Updating
  a mapping leaves old gauge registrations and already-staked NFT custody intact;
  it does not automatically unstake or move positions.
- Discovery helpers are created locally **before** `startBroadcast`; they are not
  additional production contracts and are not included in verification counts.

Registering a gauge does not configure a valuation oracle, permit borrowing
against its tokens, or add the pool to either app's product catalog. Strategy is
eligible here; the earlier exclusion applies to lending collateral only. Broad
staking registration does not promise every pool has sufficient liquidity,
TWAP history, routing or token behavior for every automation operation.

## Fresh full-stack deployment

Run from this protocol worktree. The existing environment's `ALCHEMY_API_KEY`
automatically supplies the Base RPC; alternatively export `BASE_RPC_URL` for a
Base provider with historical state. Do not print credentials into logs.

```bash
bash script/deploy-aero-protocol.sh --dry-run
# After reviewing the successful rehearsal, pause Base bots sharing account deployer:
bash script/deploy-aero-protocol.sh --broadcast
# Source verification requires ETHERSCAN_API_KEY:
bash script/deploy-aero-protocol.sh --verify
```

The script deploys VaultLib plus the ten contracts (oracle, IRM, vault, V3Utils,
GaugeManager, leverage transformer, AutoRangeAndCompound, AutoExit, liquidator,
PoolsideFactory). It preflights the full eligible gauge list before broadcast and
registers it on the fresh manager. The six existing lending pools remain mandatory;
invalid/inactive required gauges fail preflight. Collateral assets and oracle
parameters remain USDC/WETH/cbBTC, fees remain Advanced/fallback 5% and Simple 10%,
and the initial global debt limit remains zero. Poolside retains 1% swap-slippage
limits. No existing user position is migrated.

Sign with the existing local Foundry account `deployer`
(`0x83681C14770b44361e21Faf91D8325423365eA5C`). The script nominates Base Safe
`0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9` for the seven two-step ownership
transfers; IRM transfers immediately. Safe acceptance and borrowing activation
remain separate actions. Existing handoff tooling applies to the new broadcast
record; never substitute the old deployed addresses.

There are more transactions than the old six-gauge deployment. Each `setGauge`
is its own owner transaction. If interrupted, inspect receipts and the pending
nonce before using the deployment wrapper's `--resume`; never restart a fresh
broadcast blindly, and keep shared-account bots paused. A retry after a gauge
changes must be reviewed against the new binding. The old completion script is
pinned to a previous deployment and must not be used for this new stack.

After success, record actual receipt addresses, verify sources, check bindings
and owner/pending-owner state, and run a maintenance scan against the **new** manager.
Use only the actual new addresses in the Revert integration and separate Poolside
handoff; Poolside's holder/factory is not integrated into the Revert frontend.

## Periodic scan and Safe batches (default; no signing)

```bash
export AERO_GAUGE_MANAGER=0x... # actual manager from the successful new deployment
bash script/sync-aero-gauges.sh --safe
```

The script prints the current owner and each proposed pool/old gauge/new gauge,
and writes `gauge-sync/<manager>-<block>-<run-time>/summary.json` plus `batch-1.json`, etc.
Each Safe Transaction Builder file has at most 25 exact `setGauge(pool,gauge)`
calls. Zero changes produces a summary and no new batches. Runs
have separate directories (including reruns at the same pinned block): use only the directory printed by the latest run,
not old files from another run. Generated files are ignored by Git.

The batches record the **current owner**, not pending owner. Import/sign through
that owner Safe only after it has accepted ownership. While the deployer is
still owner, use the EOA execution path below instead; a pending Safe cannot
execute owner calls. Generating files does not propose, sign or submit a Safe
transaction. Review fresh scan results before signing: pool bindings may change
between discovery and execution, in which case on-chain validation can revert.

This command can be scheduled every six hours by an operator, with the working
directory, `AERO_GAUGE_MANAGER` and RPC credentials supplied securely by the job's
environment. It needs no wallet password. No cron/systemd job or production daemon
is installed by this change. The monorepo's old gauge-tracker remains a legacy
Aerodrome service; use this new Aero command rather than repointing that service
without adapting its legacy interfaces. Owner transactions remain an explicit
step after the read-only scheduled scan.

## EOA execution before Safe acceptance

```bash
export AERO_GAUGE_MANAGER=0x... # explicit target required every time
bash script/sync-aero-gauges.sh --dry-run
bash script/sync-aero-gauges.sh --broadcast
```

Defaults to local account `deployer` and its known sender address. If needed,
set both `AERO_GAUGE_ACCOUNT` and `AERO_GAUGE_SENDER` to the intended local signer.
The sender must equal the current manager owner; contract owners must use Safe
batches. Pause bots sharing this signer before broadcast. After any partial
failure, confirm receipts and wait for pending transactions to settle, then
rescan/re-run: already-applied mappings are omitted. There is intentionally no
maintenance `--resume` shortcut that could replay a stale discovery plan.

`AERO_FORK_BLOCK` may pin dry runs and Safe previews for reproducibility, but is
rejected for broadcast. Unset it for the current-state scan used for execution.

## Validation commands

```bash
# BASE_RPC_URL must be exported for forge tests (unlike the shell wrappers):
forge test --match-path 'test/fork/Aero*.t.sol' -vv
AERO_FORK_BLOCK=53296669 bash script/deploy-aero-protocol.sh --dry-run
AERO_GAUGE_MANAGER=0x36F20A7859E25fC9102F761aCBfbD9AfE78924e6 \
  AERO_FORK_BLOCK=53296669 bash script/sync-aero-gauges.sh --safe
```

The existing address in the last command is a read-only historical validation
target, not the manager to use after the forthcoming redeployment. Tests cover
full factory registration and a no-op second scan, later pool discovery, gauge
replacement preserving old registrations, inactive/missing/incompatible gauges,
zero-liquidity eligibility, wrong-chain/manager rejection and executable Safe
payloads. Full deployment tests cover custody, debt-free Poolside flows, borrowing
on the unchanged collateral set, ownership handoff and compounding routes.

## Recorded rehearsal results

At Base block 53,296,669 the full deployment dry-run succeeded with 302 transactions:
11 creations (VaultLib plus ten contracts) and 258 gauge registrations. The factory
had 525 pools: 258 compatible activated gauges and 267 pools with no gauge; none
were inactive or incompatible. Foundry estimated 93,542,491 gas including padding.
The existing manager needed 252 updates; the periodic command exported 11 batches
of at most 25 calls, and its EOA dry-run succeeded. Parsed batches contained exactly
252 distinct zero-value calls to the expected manager with the expected selector.

All 30 relevant fork tests passed (10 sync, 17 deployment lifecycle, 3 root
settlement). All eleven compiled production runtimes were byte-for-byte identical
to the merged baseline build artifacts and remained under EIP-170. No `src/` edits,
production broadcasts, ownership acceptances or scheduler changes were made. See
[aero-gauge-sync-validation.json](aero-gauge-sync-validation.json).
