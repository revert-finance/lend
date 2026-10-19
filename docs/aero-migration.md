# Aero reward ownership adapter

Updated: 2026-10-18

This is the first contract implementation slice, based on Lend's deployed
Aerodrome source baseline `ff9e75afbdd9af847e5a5c026466e179027da490`.
The Aero contract version is maintained independently on branch `aero`;
`aerodrome-slipstream` is the comparison baseline, not the intended merge target.
Subsequent Aero implementation PRs should target `aero`.
It does not migrate loans, lender shares, or existing NFTs. Existing deployments
must remain available for runoff. No production transaction has been sent.

## Supported settlement mode

On this branch, `src/GaugeManager.sol` implements the Aero changes directly.
The initial `AeroGaugeManager` subclass has been removed; there is one production
manager implementation. Compare it against the deployed Aerodrome baseline with:

```bash
git diff ff9e75afbdd9af847e5a5c026466e179027da490 -- src/GaugeManager.sol src/interfaces/aero/IAeroGauge.sol
```

`GaugeManager` supports the direct **leaf receipt-token** delivery path only.
Its inherited `aeroToken` getter refers to the local `RECEIPT_TOKEN`, not the old
AERO token or necessarily the root token. The manager checks the gauge's NPM,
pool, voter receipt token, and handler receipt-token/voter bindings when registering
a gauge. These getter checks do not authenticate arbitrary bytecode: configured
gauges, immutable voters/handlers, NPM, token and vault remain trusted dependencies
whose deployed source must be verified before launch.

The root handler automatically redeems receipts and can accumulate sub-minimum
amounts in `pendingRedeems[recipient]`. That is an additional shared-recipient
liability which this adapter does not handle. Root handlers are rejected during
registration and script preflight. Do not remove that check to force deployment.
Final Base settlement mode and addresses remain unverified.

Primary source snapshots:

- [CLGauge cbee648](https://github.com/dromos-labs/metadex-slipstream-public/blob/cbee64820898fbce295292a510522694eccc60c5/contracts/gauge/CLGauge.sol)
- [Leaf delivery](https://github.com/dromos-labs/metadex-public/blob/0058bd9b1d49b0fb0a6d130dd51886b2c64e3d99/V3/src/handlers/LeafEmissionsHandler.sol)
- [Root delivery](https://github.com/dromos-labs/metadex-public/blob/0058bd9b1d49b0fb0a6d130dd51886b2c64e3d99/V3/src/handlers/RootEmissionsHandler.sol)

## Accounting and exits

1. Unstaking calls the upstream withdrawal directly. CLGauge claims the
   position's net emissions to the manager, or on a failed mint adds them to
   `deferredEmissions[manager]`; there is no separate pre-claim. Standalone
   claims and compounding first recover account-wide deferred rewards with an
   empty NFT list into a reserved balance, then measure the position's delta.
2. Record any increase in `deferredEmissions[manager]` for the economic owner
   returned by the vault **before** returning the NFT, net of upstream
   penalties/referrals. A bucket that disagrees with the recorded batch emits
   `DeferredBatchOutOfSync` and never blocks the exit; recovery stays strict.
3. Track liabilities by `(gauge, batch, owner)`. A successful recovery closes a
   batch and reserves its receipt tokens. New deferrals start a new batch. Funded
   older batches can be paid even if the next batch cannot currently be recovered.
4. The owner calls `claimDeferredRewards(gauge, batch, recipient)` independently
   of current NFT custody/ownership. It recovers that batch if needed. Anyone may
   call `recoverDeferredRewards(gauge)` but cannot redirect the proceeds.
5. Compounding only spends the selected position's newly claimed tokens. Admin
   sweeps subtract `reservedRewards`. Withdrawal-time rewards and NPM fee deltas
   go to the withdrawing owner, counting a receipt/pool-token overlap once.

`positionRewards(tokenId)` removes account-wide deferrals from the upstream
singleton earnings value. Indexers should track `DeferredRewardRecorded`,
`DeferredRewardsRecovered`, and `DeferredRewardsClaimed`; batch/owner mappings
remain available after the NFT exits and after a pool's gauge is replaced.
No frontend, indexer, keeper, or claim UI has been wired in this slice.

Claim-on-withdraw does not guarantee an exit through every upstream failure.
Pool settlement, forfeiture, token/NFT transfers and downstream vault checks can
still revert. Re-range/compound restaking can also fail and roll back atomically;
a separate unstake remains the tested escape path for a deposit-only outage.
Never assume a recovered receipt equals a fixed amount of root AERO.

Compounding requires actual local receipt-token swap liquidity and valid TWAPs.
Old AERO routes cannot simply be copied. Leave reward routes empty until verified;
staking, withdrawal and standalone claims do not need those routes.

## Early-unstake penalty window

CLGauge records `depositBlock[tokenId]` on every deposit. While
`block.number < depositBlock + minStakeBlocks` (from
`CLGaugeFactory.effectivePenaltyConfig(gauge)`), every claim forfeits
`penaltyRate / 1e6` of the position's reward to the voter. The pinned upstream
defaults are 5 blocks and 100%; governance can raise the block count per gauge.
Upstream `earned()`, and therefore `positionRewards()`, already report the net.

Compounding withdraws and re-deposits the NFT, which restarts that clock.
`compoundRewards` therefore reverts with `InsidePenaltyWindow` while the position
is inside the window: neither the compound's own claim nor a keeper loop that
compounds more often than `minStakeBlocks` can forfeit rewards.
`penaltyWindowEnd(tokenId)` returns the first block at which the next compound
is allowed (0 when no penalty applies). Every `V3Vault.transform` of a staked
position, including re-ranges without reward compounding, also unstakes and
restakes: the upstream withdraw claims the position at the penalized rate inside
the window and the new deposit restarts the clock. The operator entrypoints of
`AutoRangeAndCompound` therefore enforce the window on-chain for staked positions
(Cantina LEND-4): `executeWithVault` and `autoCompoundWithVault` revert with
`NotReady` before `penaltyWindowEnd`, and the `...AndRewardCompound` variants
revert with `InsidePenaltyWindow` from the strict compound they request. Unstaked
positions and vaults without a gauge manager are not affected, and a keeper
should still schedule at or after that block because an earlier call only wastes
gas. Transforms the owner starts through the vault directly, or through a
transform delegate the owner approved, and direct `claimRewards` calls inside
the window stay the owner's choice and pay the upstream-netted amount: the vault
cannot tell a re-range from an exit, so it does not enforce the window itself.

## Operator-managed staking (compound-only)

Whether a vault position is staked is the depositor's choice, but an owner can
hand that choice to the `AutoRangeAndCompound` operator per position with
`configStakingManagement(tokenId, vault, true)`. The operator then moves the
position between staked and unstaked custody through the vault with
`autoCompoundWithVaultAndRewardCompound` and `executeWithVaultAndRewardCompound`,
passing `rewardParams.stakeTarget` (`Keep`, `Staked`, `Unstaked`). Every move is a single
`V3Vault.transformWithRewardCompound` transform, so the policy is compound-only by
construction:

- Staked rewards are compounded before the unstake. `transform` itself now does
  this best-effort for every staked position (defaults: no minimum, even split,
  current block); the explicit variants compound with the operator's parameters
  and revert if that fails. If compounding is impossible (missing reward route,
  failed mint, or the penalty window on a transform the owner or an approved
  delegate starts directly) the plain transform falls back to the payout or
  deferral the unstake performs.
  Liquidation and removal keep paying out.
- Fees are compounded before a stake. A custody change runs
  `autoCompoundForStakeChange`, which ignores the configured `autoCompound` flag
  and minimum-fee thresholds so dust never stalls it.
- Ending staked from unstaked custody applies the buffered health check that
  `stakePosition` uses, because staking switches to the fee-less valuation.

Guards: a real custody change needs the owner opt-in, respects the owner-set
`stakeChangeCooldownBlocks` between changes of the same position, and never
unstakes before `GaugeManager.penaltyWindowEnd(tokenId)`. `Keep`, or a target
equal to the current state, needs no opt-in. The opt-in records the consenting
owner per position and vault (`stakingConsent[tokenId][vault]`) and applies only
while that address is that vault's current owner of the position: it is suspended
while the position is out of the vault or owned by someone else, never carries to
another vault, re-applies if the same owner re-deposits the same position into the
same vault, and ends when the owner revokes it with
`configStakingManagement(tokenId, vault, false)`. It migrates to the replacement
token on a re-range. The vault enforces consent at its boundary
too: `transformWithRewardCompound` honours a custody change only when called by
the loan owner or by the allowlisted transformer contract itself, never by a
generic `approveTransform` delegate. The stake/unstake decision itself is
off-chain: the keeper compares emissions per unit of staked liquidity with fees
per unit of in-range liquidity, prices the receipt token at its realisable value,
and only stakes positions whose pool has reward swap routes configured, since
without a route rewards cannot be compounded.

Vault size: `V3Vault` was above EIP-170 on this branch before this feature. The
liquidation math, the liquidated-share transfer, reserve socialization and the
per-token collateral accounting now live in the external library
`src/utils/VaultLib.sol` (DELEGATECALL, linked by Foundry in tests and scripts),
and the compound-before-unstake step runs in `GaugeManager.unstakeIfStakedCompounding`.
The margin is small; check `forge build --sizes` after any vault change.

## Reproduce the checks

Use Foundry with solc 0.8.24 and 0.7.6 available. Initialize the pinned
dependencies, build the upstream fixture, then run the unit and mock-vault
suites and the broadcast-disabled local deployment:

```bash
git submodule update --init --recursive
forge build --root fixtures/upstream-gauge
forge test --match-path 'test/{unit,integration/aerodrome}/*.t.sol'
forge script script/DeployAeroGaugeManagerLocal.s.sol:DeployAeroGaugeManagerLocal --sig 'run()'
```

The separate fixture build compiles the **unmodified** upstream CLGauge at
`cbee64820898fbce295292a510522694eccc60c5` with solc 0.7.6 and OpenZeppelin
`04695aecbd4d17dddfd55de766d10e3805d6f42f` (3.4.2-solc-0.7). The main tests read
that artifact via a narrowly scoped Foundry read permission. Build it before
running the unit suite, including in CI. The suites cover receipt accounting
(including a 256-case two-owner conservation fuzz), the pinned upstream gauge
(deferral, penalty/referral netting, the compound penalty window), deployment
preflight, and vault staking, removal, liquidation, transformation and
compounding against the deferring gauge double in `test/mocks/AeroGaugeFixture.sol`.
Full Aero pool, voter, handler, bridge and NPM deployments are not exercised:
these dependencies are controlled fixtures. The local script uses an actual fresh
V3Vault with unconfigured lending dependencies to validate adapter deployment and
wiring; it is not a lending deployment. Check the adapter's runtime size against
EIP-170's 24,576-byte limit with `forge build --sizes`. Target Base fork
simulation, full Aero core integration and production deployment have **not**
been performed; local mocks do not validate final launch behavior.

Legacy Base gauge fork tests and the old `DeployAerodromeProtocol` and
`ConfigureGauges` scripts are specific to the `aerodrome-slipstream` baseline
`ff9e75afbdd9af847e5a5c026466e179027da490` and were removed from this branch; run
them from that commit. Keep future edits focused on required Aero behavior and
avoid unrelated refactors or reformatting that obscure the comparison with the
deployed implementation.

## Deployment inputs and dependency map

Production entrypoint: `script/DeployAeroGaugeManager.s.sol:DeployAeroGaugeManager`.
This script deploys **only the manager**, configures gauges/optional reward routes,
binds a separately prepared fresh vault, sets the withdrawer and starts two-step
ownership transfer. It does not deploy the replacement oracle, vault or automators.

| Environment variable | Required value / current status |
|---|---|
| `AERO_CHAIN_ID` | Verified target chain ID; Base is 8453, local fixture is 31337 |
| `AERO_DEPLOYER` | Signing address; must own the fresh, unbound vault |
| `AERO_NPM` | Verified new Aero NPM; unresolved. Legacy `0x827922686190790b37229fd06084350e74485b72` is not a substitute |
| `AERO_FACTORY` | Verified new NPM factory; unresolved. Legacy `0x5e7bb104d84c7cb9b682aac2f3d509f5f406809a` is not a substitute |
| `AERO_RECEIPT_TOKEN` | Verified local receipt token; unresolved. Do not use legacy `0x940181a94a35a4569e4529a3cdfb74e38fd98631` |
| `AERO_NEW_VAULT` | Fresh vault bound to that NPM with `gaugeManager() == 0`; not any existing Aerodrome vault |
| `AERO_OWNER` | Chosen governance owner; must accept ownership after deployment |
| `AERO_WITHDRAWER` | Chosen address allowed to sweep surplus, excluding user reserves |
| `AERO_ROUTER` | Verified compatible router, or explicit zero address if unused |
| `AERO_ALLOWANCE_HOLDER` | Verified allowance holder, or explicit zero address if unused |
| `AERO_POOLS`, `AERO_GAUGES` | Matching, nonempty comma-separated address lists from verified launch deployment |
| `AERO_REWARD_BASES`, `AERO_REWARD_POOLS` | Matching comma-separated lists for receipt-token swaps; export both as empty strings to disable routes |
| `AERO_RPC_URL` | Target RPC passed on CLI; do not print credential-bearing URLs |

Local outputs are ephemeral simulation addresses, not deployable launch constants.
No complete final Base manifest or new vault configuration is verified, so a
target-chain fork simulation and production deployment remain **incomplete**.
The existing current vault has already used its one-time manager setter.

Once launch dependencies, their deployed source, the new vault and settlement mode
are verified, export the inputs above and simulate without a signing key:

```bash
forge script script/DeployAeroGaugeManager.s.sol:DeployAeroGaugeManager --rpc-url "$AERO_RPC_URL" --sig 'run()'
```

Only after the target simulation, review and deployment authorization, use a
Foundry keystore account matching `AERO_DEPLOYER` (no private key in source):

```bash
forge script script/DeployAeroGaugeManager.s.sol:DeployAeroGaugeManager --rpc-url "$AERO_RPC_URL" --sig 'run()' --account "$AERO_DEPLOYER_ACCOUNT" --broadcast --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

`--verify` uses the selected chain's Etherscan-compatible verifier; configure
`--verifier-url` for a different explorer. A standalone retry, after exporting
the deployed `AERO_MANAGER`, is:

```bash
forge verify-contract "$AERO_MANAGER" src/GaugeManager.sol:GaugeManager --chain "$AERO_CHAIN_ID" --watch --etherscan-api-key "$ETHERSCAN_API_KEY" --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address)' "$AERO_NPM" "$AERO_RECEIPT_TOKEN" "$AERO_NEW_VAULT" "$AERO_ROUTER" "$AERO_ALLOWANCE_HOLDER")"
```

After broadcast, verify source, immutable bindings, every configured gauge/route,
and `withdrawer()`. If owner differs from deployer, the designated owner must
execute `acceptOwnership()` and confirm `owner()`/`pendingOwner()`. Vault ownership
transfer and the wider protocol's risk/oracle/automation configuration belong to
the new vault deployment flow and must be completed before enabling users.

## Preflight and partial-deployment recovery

Preflight mirrors the manager's pool-to-gauge check and reward-route token/factory
validation, including rejecting zero/receipt-token reward bases and allowing a
zero pool to remove a route. `GaugeManager.setGauge` retains the original explicit
`onlyOwner` guard; it no longer depends on a superclass call for authorization.

Foundry executes the script and normally simulates its collected transactions
before broadcasting. Invalid static configuration should therefore fail before
submission even without these extra preflight checks. The checks provide earlier,
specific errors; they do not make a multi-transaction deployment atomic or prevent
state changes between simulation and mining. See
[Foundry scripting internals](https://www.getfoundry.sh/forge/scripting-internals).

If a live broadcast is interrupted, work from `protocols/lend`:

1. Preserve the original `broadcast/` and `cache/` artifacts, including any private
   `.recovery.json` state. Keep recovery state private and use the same Foundry
   version, or a newer version that supports its recovery format. Reconcile every
   submitted transaction's receipt and the deployer's pending/latest nonce. Check
   the actual manager address, configured gauges/routes, vault binding, owner,
   pending owner and withdrawer. A failure does not prove later transactions were
   never submitted or that the vault is still unbound.
2. For a transient interruption with a still-valid saved plan and compatible
   sender nonces, continue that plan with the original signing account:

   ```bash
   forge script script/DeployAeroGaugeManager.s.sol:DeployAeroGaugeManager --rpc-url "$AERO_RPC_URL" --sig 'run()' --account "$AERO_DEPLOYER_ACCOUNT" --broadcast --resume
   ```

   Resume uses the saved transactions and skips the ordinary transaction simulation.
   Editing environment variables or the script does not repair saved arguments.
   Do not use it blindly after a mined revert, a config change or nonce consumption
   by another process. Inspect the outstanding calls against current state first.
3. If the plan needs correction, reconcile pending transactions before issuing
   new ones. Reuse the existing deployed manager and finish only the missing or
   corrected configuration calls, signed by its **current** owner. Set
   `AERO_MANAGER` to the receipt-confirmed address, `AERO_CONFIG_ACCOUNT` to that
   owner's signing account, and `POOL`, `GAUGE`, `REWARD_BASE`, `REWARD_POOL` to
   the verified pair being repaired. Simulate the corrected calls before sending:

   ```bash
   cast send "$AERO_MANAGER" 'setGauge(address,address)' "$POOL" "$GAUGE" --rpc-url "$AERO_RPC_URL" --account "$AERO_CONFIG_ACCOUNT"
   cast send "$AERO_MANAGER" 'setRewardBasePool(address,address)' "$REWARD_BASE" "$REWARD_POOL" --rpc-url "$AERO_RPC_URL" --account "$AERO_CONFIG_ACCOUNT"
   cast send "$AERO_MANAGER" 'setWithdrawer(address)' "$AERO_WITHDRAWER" --rpc-url "$AERO_RPC_URL" --account "$AERO_CONFIG_ACCOUNT"
   ```

   These are live repair commands, not commands to run wholesale. Repeat only the
   calls needed for the reviewed configuration. Reverify all gauges/routes before
   binding the vault. If `gaugeManager()` is zero, the vault's current owner can
   execute `setGaugeManager(AERO_MANAGER)`. If already equal to this manager, skip
   that one-time call. If it points elsewhere, stop and reconcile the discrepancy;
   this vault cannot be rebound. Complete `transferOwnership(AERO_OWNER)` and
   `acceptOwnership()` only as needed according to current owner/pending-owner
   state. A pending owner cannot configure the manager before accepting ownership.
4. Reverify source and all final bindings/roles. Do not rerun `run()` as a repair:
   it creates another manager when the vault is unbound, and rejects an already
   bound vault. It is not an idempotent configuration/resume entrypoint.

## Remaining migration work

- Confirm final Base handler/token/addresses and deployment blocks. If Base uses
  root redemption, implement and test an adapter for that settlement mode.
- Full-stack target fork: real vault remove, liquidation and transformations;
  actual core delivery, caps, retirement and minimum-stake boundary behavior.
- Legacy retirement fork tests and refreshed exposure inventory for all three
  existing manager/vault families.
- Replacement NPM-bound oracle, vault, utilities, automators and liquidator;
  validated risk configuration and complete protocol deployment script.
- Receipt redemption UX, deferred-claim indexing/UI, keeper routes and loan/share
  migration flows. Audit the new accounting before production enablement.
