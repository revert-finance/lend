# Poolside position holder

Poolside is the new product name; earlier deployments retain the PoolPeach contract names.
This custody adapter adds a factory and per-position holders. Debt-free automation requires the
V3Vault version that skips collateral-health valuation when final debt is zero; earlier deployed vaults
do not have that exception. GaugeManager, V3Utils, AutoRangeAndCompound and AutoExit logic is unchanged.
This version is not included in the existing Cantina scan pinned to `b16c84df570fe5956e5749e94b8572e3195fa5e9`.

## Exit settlement update (2026-11-05)

This version adds **exit-time conversion only**. Compounding, fee charging, NFT/range management,
keeper permissions and deferred-reward claims are unchanged. Leftovers remain in the holder until exit;
there is no new reinvestment function or automatic late-reward settlement. Existing positions are tests;
this release does not migrate them. Before broadcasting, prepare the factory deployment against the current
verified suite: the existing standalone factory script is still pinned to the older 2026-10-29 stack and
must not be reused unchanged for this release.

Both manual USDC withdrawal and AutoExit now attempt to convert available token0, token1, WETH/native
refunds and delivered reward tokens to the vault asset before paying the fixed beneficiary. Each token's
conversion is atomic and best-effort: if a route is unavailable, TWAP/history is invalid, output rounds to
zero, the swap only partially fills, or execution exceeds its price limit, the complete conversion for
that token rolls back and the original token is returned in kind. This fallback is not necessarily tiny
dust: **USDC-only payout is not guaranteed when conversion is unsafe or unavailable.** Principal is not
held waiting for a quote, and the existing beneficiary NFT withdrawal escape remains available.

Routes cannot be supplied by a keeper: a position token trades directly through its NFT's pool when the
other token is the asset; otherwise the configured GaugeManager reward-base pools provide a path through
the reward token. Each hop authenticates the factory/pair, uses AutoExit's current TWAP duration and maximum
tick deviation, and caps execution loss at 1% of the pre-swap spot quote, including pool fees. A two-hop
route has a per-hop limit, not a 1% end-to-end limit. Full input consumption and actual output balances are
checked. The callback only pays an authenticated in-flight pool once, up to the specified input. No new
application swap/reinvestment fee is charged; existing AutoExit fees and underlying DEX fees still apply.

`PoolsidePositionDeployer` is a linked Solidity library containing holder creation code, required to keep
both factory and creation library below Base's 24,576-byte runtime limit. Its delegatecall executes CREATE
in the factory context, preserving the holder's immutable registry. It has no storage writes or configurable
target. Deploy and verify this library and the replacement factory; no existing protocol contract needs
redeployment for this change. `Swapper` only gains a virtual callback annotation so this holder can enforce
the stricter callback scope; existing inheritors retain the same callback implementation.

## Purpose and scope

A user creates a fresh Aero position, enables managed staking and selects an AutoExit rule in one transaction.
Each position gets its own `PoolsidePosition`, with the caller recorded as its immutable beneficiary.
The holder is the owner recorded in the existing vault. These positions do not borrow; there is no borrowing,
arbitrary execution, beneficiary-transfer, auto-range configuration or generic transformer entrypoint.

`PoolsideFactory` records the newly minted NFT and deploys the holder in the same call. The real token ID is
returned by V3Utils and cross-checked against the authenticated ERC721 callback; IDs are never predicted.
The holder cannot import or re-enroll existing NFTs. Anyone may call the factory, so registration proves
creation through this factory, not which website someone used.

Separate holders intentionally trade deployment gas for simple accounting. GaugeManager keys deferred claims
by owner/gauge/batch or owner, not always by NFT: a shared holder would need a separate allocation ledger.
Here, every reward owed to a holder belongs to its one beneficiary, even after the NFT leaves.

## Creation and funding

Call `PoolsideFactory.create(mintParams, exitConfig, initiallyStake)`:

1. Check that AutoExit authorizes this factory, that the pool has a configured gauge, and that inputs fit the
   supported two-token funding path.
2. Deploy a holder for `msg.sender`. Pull exactly the requested ERC20 amounts and approve only those amounts to
   the immutable V3Utils. Reject transfers that deliver a different amount. ETH may fund all or part of the WETH
   side, reducing the corresponding ERC20 pull.
3. Call V3Utils to mint into that holder. Force the beneficiary to the caller. ERC20-funded leftovers return directly
   to the caller; native-funded leftovers go through the holder, which wraps ETH and forwards WETH and remaining
   tokens to the beneficiary within the same transaction. Contract beneficiaries need not accept native ETH refunds.
   Callers cannot override the NFT receiver or callback data. Clear factory-to-V3Utils allowances afterward.
4. Settle mint refunds, then configure AutoExit while the holder directly owns the NFT. Deposit into the vault under the holder's ownership,
   approve only the existing AutoRangeAndCompound transformer, select Simple compounding fees (currently 10%)
   with recurring compounding enabled and 1% per-token swap tolerance, keep range changes disabled, and enable staking management.
5. Optionally stake immediately, then publish `PositionCreated(tokenId, holder, beneficiary)`.

Debt-free creation and vault health checks do not require per-token valuation-oracle configuration.
The vault's health assertion skips valuation only when the final debt is zero, including after a transform.
Borrowing directly or inside a transform still requires the normal oracle and collateral checks. This does
not change swap slippage/TWAP checks, authorized custody transitions, consent, cooldowns, or gauge validation.
Each pool still needs `GaugeManager.setGauge(pool, gauge)` before creation, including unstaked creation.

Valuation APIs such as `loanInfo()` retain their meaning and may revert when a token has no usable oracle.
Clients must not infer debt or display a zero valuation from that failure. Poolside debt-free position
checks can read `loans(tokenId)` (debt shares), `ownerOf`, and the holder registry instead. The current
Poolside frontend inspected at monorepo commit `1eb9c6052` and the on-chain automation do not call `loanInfo()`; Revert lending views and MCP planners
still use it and retain their fail-closed behavior. Verify the running keeper implementation before enabling
new pools, especially any off-chain eligibility filter that assumes every vault NFT has a valuation.

This is a new-deployment feature. Deploy a new vault and a GaugeManager constructed with that vault,
register supported gauges/reward routes, bind the manager and staking policy, allowlist the transformer,
and register the new vault with AutoRangeAndCompound. Deploy this factory against that stack and authorize
it in AutoExit. Compatible existing automation, oracle, IRM and V3Utils contracts can be reused with their
required owner-controlled configuration; no patch is applied to old immutable deployments. A factory-only
replacement against the old vault is insufficient. Do not run the existing factory-only deployment script
against its pinned old vault for this feature; the full `deploy-aero-protocol.sh` path deploys a coherent fresh
stack, or prepare a dedicated replacement-stack script with reviewed addresses. Keep lending disabled and stock collateral factors zero
unless separately approved; these settings are independent of Poolside support. Existing holders do not
switch stacks automatically, and this factory does not import existing NFTs.

Failure at any stage reverts funding, deployment, minting, configuration and registration together. The factory
retains no intended user balances. Accidental transfers to the factory are not recoverable in this draft;
send funds only through `create`, never directly to the factory.

**One transaction means the create-and-setup operation.** Ordinary ERC20 approvals to this new factory must
already exist. Native ETH funding needs no WETH allowance; a tested ETH-only, one-sided mint needs no ERC20
approvals at all. This draft has no permit/Permit2 entrypoint or third-token funding, and does not promise a
single wallet interaction for every first-time ERC20 user. Existing V3Utils approvals do not authorize this factory.
Swaps use the existing V3Utils swap infrastructure; the fork suite below exercises creation without swaps.

## Ownership, automation and exits

The ownership chain is `beneficiary -> per-position holder -> vault -> optional gauge custody`.
Only the beneficiary can pause/resume staking consent or AutoExit, withdraw the NFT, or claim residual rewards.
Exit prices/fees are selected at creation and cannot be edited in place in this draft; AutoExit pause/resume
preserves that original rule. No holder or factory admin can change the beneficiary, redirect funds or upgrade code.
The existing protocol dependency owners retain their existing configuration powers.

Staking uses the existing keeper's `autoCompoundWithVaultAndRewardCompound` path, including its consent, cooldown,
fee and penalty-window checks. Creation also enables recurring fee/reward compounding without a custody change. Equal range deltas keep
auto-range/replacement NFTs disabled. Every exit clears both recurring compounding and staking consent.

For automated exit, an existing AutoExit operator calls `factory.executeExit(params)`. The factory:

1. Checks its caller against AutoExit's current operator mapping and locates an active holder.
2. Asks the holder to clear recurring compounding, revoke staking consent and transformer approval, withdraw from the vault (unstaking if needed),
   and grant a temporary per-token approval to AutoExit.
3. Calls the unchanged AutoExit as its registered operator. Its configured trigger, maximum fee, deadline, swap
   checks and liquidity-removal bounds remain enforced. The existing keeper remains trusted for parameters the
   existing AutoExit delegates to it; this adapter does not strengthen those underlying trust assumptions.
4. Clears any remaining exit configuration and NFT approval, closes the registry entry, retains the emptied NFT,
   and settles available balances through the fixed routes above before paying the beneficiary. Native proceeds are wrapped into WETH before conversion.
   Only the beneficiary can later retrieve the NFT through `holder.claimNFT(recipient)`.

All four steps are one transaction. A failed trigger, swap or proceeds settlement restores custody,
permissions and registry state. The factory must be registered as an AutoExit operator **once**; each new holder
needs no governance transaction. Revoking that registration prevents automated exits but does not disable the
beneficiary's direct withdrawal.

### Agreed policy: wait out early-unstake penalties

Both automatic exits and automated staking changes wait until `GaugeManager.penaltyWindowEnd(tokenId)` when
the position is staked. This policy was confirmed on 2026-10-28. **A stop-loss can therefore be delayed during
that window.** Once it ends, the exit condition must still hold at execution; the first price crossing is not
latched or guaranteed. Keepers must retry eligible exits and read the current on-chain window rather than
hardcoding seven blocks. At Base block 53180616 all six configured collateral pools had a seven-block window
(approximately 14 seconds) and a 100% penalty on emissions claimed inside it; Aero can change those settings.
Beneficiary-initiated NFT or asset withdrawals have no added penalty-window or price-trigger restriction; upstream withdrawal
rules still apply, including any reward penalty. The frontend must explain that distinction.

### User withdrawal and remaining rewards

`holder.withdraw()` returns the NFT with its remaining liquidity to the beneficiary. Alternatively, the beneficiary
can call `holder.withdrawTo(recipient)` to select another NFT recipient, including when the beneficiary cannot
receive ERC721s. Both clear automation permissions and the old exit rule, and remove the position from active
management. Neither liquidates the LP nor requires deferred reward redemption. Invalid NFT delivery reverts a
manual withdrawal atomically, allowing the beneficiary to retry with another recipient.

`holder.withdrawToAsset(instructions, minAssets)` closes the full LP through the existing V3Utils and pays
USDC (the immutable vault's asset) to the beneficiary in one transaction. The holder forces the action to
`WITHDRAW_AND_COLLECT_AND_SWAP`, all remaining liquidity and fees, the output asset, and its own address as
V3Utils recipient. The beneficiary supplies the existing V3Utils swap quote bytes, removal/swap minima and
deadline. `minAssets` bounds the newly received USDC from that operation; pre-existing balances and any
withdrawal-time reward delivery cannot pad that minimum. Failure restores custody, permissions and accounting.

The exit also attempts conversion of available token0/token1 leftovers, WETH (including wrapped native ETH)
and delivered GaugeManager reward tokens, then forwards all USDC to the beneficiary. An unsafe or unavailable
conversion returns its original input in kind and emits `UnconvertedBalance(token, amount)`. Deferred rewards not delivered yet and unrelated accidentally transferred tokens remain
recoverable through the existing claim functions. The emptied NFT remains separately recoverable using
`claimNFT(recipient)`; beneficiaries without an ERC721 receiver can still receive their USDC.

**Poolside quote integration:** reuse the Revert SPA V3Utils withdrawal quote encoding. The swap taker is the
configured V3Utils address, not the holder or factory. Request zero application swap fees, omitting
`swapFeeBps`, `swapFeeRecipient`, `swapFeeToken` and `tradeSurplusRecipient`. Neither this holder exit nor V3Utils
charges an exit fee; underlying DEX fees still apply. The holder cannot remove fees embedded in opaque router
calldata. The existing backend Poolside waiver is restricted by venue, taker and token pair, so integration must
verify the waiver covers each supported exit rather than assuming a client label alone makes quotes fee-free.
Universal Router remains supported. Its commands must consume or refund unused input to V3Utils (for example,
a final input-token `SWEEP` to V3Utils), so V3Utils can forward leftovers to the holder. The holder snapshots
both position-token balances at Universal Router immediately before execution and reverts with
`UnspentRouterInput` if either balance increases. Pre-existing router balances do not by themselves block an
exit. The aggregate USDC minimum remains enforced separately. This is a net-balance guard for the two position
tokens, not validation of arbitrary router commands, recipients, intermediate tokens or native ETH; quote
construction and appropriate output minima remain required.
The added balance settlement uses direct pool swaps and accepts no router calldata. The existing beneficiary-supplied
V3Utils NFT withdrawal quote, router input-refund guards and `minAssets` check remain unchanged; that minimum is
checked before leftover settlement, so existing balances cannot mask a failed NFT conversion. The returned `assets`
is the total USDC paid, including existing USDC and successful leftover conversions. This protocol change does not
modify the frontend or quote service.

AutoExit pays proceeds without delivering its emptied NFT. The closed holder retains it until the beneficiary
calls `holder.claimNFT(recipient)`; a failed retrieval cannot undo the earlier exit or proceeds payment. Neither
recipient choice changes the immutable beneficiary or redirects its token balances and deferred rewards.

Immediate balances received by the holder during staking/unstaking remain payable through `claimTokens` or
`claimNative`. Deferred batch claims and root claims have dedicated forwarding functions that always pay the
beneficiary. These functions work after closure. An unfunded or failing deferred claim does not block a separate
principal withdrawal. Other users and operators cannot claim a holder's balances or redirect claim proceeds.
The immutable manager performs the actual deferred-accounting/funding checks; these functions do not manufacture
liabilities or advance funds.

## Bot and frontend handoff

- Keep the existing `withdrawToAsset(instructions, minAssets)` and `factory.executeExit(params)` ABIs.
  Settlement runs inside the exit transaction; do not add a recycling call, extra user approval or quote
  for holder leftovers. Existing NFT/AutoExit quote requirements still apply.
- Continue tracking holder balances while active, without presenting them as reinvested liquidity.
- Read `AssetSettled(beneficiary, amount)` for total USDC paid and `UnconvertedBalance(token, amount)` for
  in-kind fallback balances, alongside the existing `TokensClaimed` events. Do not count these overlapping
  events twice when recording withdrawals. Show non-USDC payouts explicitly rather than claiming all sold.
- Rewards unavailable at exit are excluded from settlement. Keep historical holder addresses and existing
  beneficiary claim paths after closure; do not present deferred rewards as paid. Automatic late recovery
  and conversion is intentionally deferred, and no new keeper claim permission is granted here.
- Deploy the linked creation library plus a replacement factory, authorize that factory in AutoExit, and
  integrate only the verified new factory address. The old holders are immutable. No production migration
  or on-chain deployment has been performed as part of this PR.

## Tracking

Pin the chain, canonical factory and its immutable NPM. Use `PositionCreated` and `PositionRemoved` plus
`factory.activeHolder(tokenId)` as the active-management source of truth. Zero means the position is no longer
managed. Staking does not remove registration when physical NFT custody changes to a gauge.

`factory.positions(tokenId)` retains the historical holder address solely for claims/recovery and provenance.
Do not interpret that mapping as active membership. After removal, Poolside must stop automation and exclude the
position from its active list, while still offering a separate way to recover any rewards owed to the old holder.
`holder.beneficiary()` resolves the end user; the vault's `ownerOf` resolves the holder, not the end user.

## Validation

Validation on 2026-11-05: 70 Poolside Base-fork tests, four shared swap-math tests and one slot0
regression passed. A factory/library deployment rehearsal at historical Base block 53269048 succeeded
without broadcasting. Mocked verification transport accepted the real dry-run initcode and rejected
altered initcode; no source was uploaded. Runtime sizes: holder 19,685 bytes, creation library 21,884,
factory 7,151 (each below 24,576). This rehearsal does not verify current production ownership/configuration.

Exit-settlement regressions cover both starting custody states, pre-existing USDC/position tokens/native
ETH/delivered rewards, missing routes, unsafe or absent TWAP history, sub-unit dust, partial fills,
unauthorized helper/callback calls, isolated two-hop accounting/rollback, deferred claims remaining intact,
non-receiver beneficiaries, and EIP-170/EIP-3860 deployment size limits.


```bash
# BASE_RPC_URL must be a Base RPC with historical state support; no signing keys are needed.
forge test --match-path 'test/poolside/*' -vv
forge fmt --check src/poolside/PoolsideFactory.sol src/poolside/PoolsidePosition.sol \
  test/poolside/PoolsideFactoryFork.t.sol
```

The fork suite uses actual Aero dependencies at Base block **53255803**, with a freshly deployed vault,
GaugeManager, factory and holders. AutoRangeAndCompound is authorized for the new vault by its owner on the fork;
production contracts and state are not modified. Coverage includes creation and initial staking, actual keeper staking and consent
revocation, exit execution, penalty policy, manual withdrawal, registry lifecycle, operator revocation, recipient
binding, fee limits, rollback on trigger/slippage/recipient failures, callback reentrancy, root/batch claim forwarding,
cross-holder isolation, residual tokens, native funding and unavailable borrowing/generic-call entrypoints. Native
refund regressions use a beneficiary contract without a payable receive/fallback, and check both WETH and non-native
refund amounts against the mint event. The WETH-refund regression reproduced `EtherSendFailed()` before the fix.
NFT-recovery regressions cover a beneficiary with no ERC721 receiver hook, beneficiary-selected manual recipients,
AutoExit proceeds paid while the empty NFT stays in the holder, separately failing/retried NFT retrieval, and
authorization and reentrancy checks on recovery. Failed NFT delivery only rolls back the manual withdrawal or
retrieval transaction; it cannot undo proceeds paid in an earlier AutoExit transaction.

Zero-debt regressions clear a pool token's configuration on the fork while retaining its registered gauge.
Both initial custody modes allow creation and manual withdrawal. Keeper compounding, staking, unstaking and
AutoExit also execute without that valuation configuration. Local vault regressions check missing-oracle
rejection for direct borrowing (including one base unit), borrowing during a previously debt-free transform,
and transforms of existing debt. `loanInfo()` still rejects unavailable valuation instead of fabricating zeros.

Deferred-liability cases seed GaugeManager accounting/storage and funding on the fork, then call its actual claim
functions. They test ownership forwarding and isolation; they do not reproduce upstream delayed minting/redemption.
Asset-exit tests execute real Universal Router WETH-to-USDC swaps on the fork from both custody states,
check aggregate minimum output, reject unauthorized callers and invalid/expired swaps, return existing balances
and leftovers, preserve deferred claims, and clear automation even when the recipient globally approves it.
Router-refund regressions reject empty commands, partial swaps without refunds and output left in the router;
partial swaps with input refunds succeed with and without pre-existing router balances. Rejected exits restore
NFT liquidity/custody, staking consent, automation configuration, registry state and token balances.
The suite does not exercise externally fetched 0x quotes, wallet prompts, production keeper scheduling, frontend/indexer
integration or every malicious dependency behavior. Existing protocol dependencies are trusted within their declared
interfaces. These are reproducible regression checks, not an audit or authorization to deploy.

## Before deployment

- Review the new custody layer independently; existing core audits do not cover it.
- Evaluate per-position deployment gas. Clones are deliberately omitted
  from this first draft to avoid adding initialization/proxy complexity.
- Review exit configuration editing and wallet funding UX as separate scope.
- Add a reviewed deployment/preflight flow, register the factory once with AutoExit, and validate selected pools.
- Wire beneficiary resolution, active registry indexing, post-closure reward recovery and the factory exit route
  into Poolside and its keeper. No frontend, keeper or production configuration is changed by this PR.
