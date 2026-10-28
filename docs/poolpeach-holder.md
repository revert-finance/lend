# PoolPeach position holder — draft for review

This is a proposed custody adapter, **not deployed or audited code**. It adds two contracts without changing
V3Vault, GaugeManager, V3Utils, AutoRangeAndCompound or AutoExit. It is not included in the existing Cantina scan
pinned to `b16c84df570fe5956e5749e94b8572e3195fa5e9`.

## Purpose and scope

A user creates a fresh Aero position, enables managed staking and selects an AutoExit rule in one transaction.
Each position gets its own `PoolPeachPosition`, with the caller recorded as its immutable beneficiary.
The holder is the owner recorded in the existing vault. These positions do not borrow; there is no borrowing,
arbitrary execution, beneficiary-transfer, auto-range configuration or generic transformer entrypoint.

`PoolPeachFactory` records the newly minted NFT and deploys the holder in the same call. The real token ID is
returned by V3Utils and cross-checked against the authenticated ERC721 callback; IDs are never predicted.
The holder cannot import or re-enroll existing NFTs. Anyone may call the factory, so registration proves
creation through this factory, not which website someone used.

Separate holders intentionally trade deployment gas for simple accounting. GaugeManager keys deferred claims
by owner/gauge/batch or owner, not always by NFT: a shared holder would need a separate allocation ledger.
Here, every reward owed to a holder belongs to its one beneficiary, even after the NFT leaves.

## Creation and funding

Call `PoolPeachFactory.create(mintParams, exitConfig, initiallyStake)`:

1. Check that AutoExit authorizes this factory, that the pool has a configured gauge, and that inputs fit the
   supported two-token funding path.
2. Deploy a holder for `msg.sender`. Pull exactly the requested ERC20 amounts and approve only those amounts to
   the immutable V3Utils. Reject transfers that deliver a different amount. ETH may fund all or part of the WETH
   side, reducing the corresponding ERC20 pull.
3. Call V3Utils to mint into that holder. Force both the beneficiary and leftover-token destination to the caller;
   callers cannot override the NFT receiver or callback data. Clear factory-to-V3Utils allowances afterward.
4. Configure AutoExit while the holder directly owns the NFT. Deposit into the vault under the holder's ownership,
   approve only the existing AutoRangeAndCompound transformer, and enable its staking-management consent.
5. Optionally stake immediately. Publish `PositionCreated(tokenId, holder, beneficiary)` only after setup succeeds.

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
fee and penalty-window checks. This draft does not configure ongoing auto-compounding without a custody change,
or auto-range/replacement NFTs. Those are separate features, not implicitly enabled by staking consent.

For automated exit, an existing AutoExit operator calls `factory.executeExit(params)`. The factory:

1. Checks its caller against AutoExit's current operator mapping and locates an active holder.
2. Asks the holder to revoke staking consent and transformer approval, withdraw from the vault (unstaking if needed),
   and grant a temporary per-token approval to AutoExit.
3. Calls the unchanged AutoExit as its registered operator. Its configured trigger, maximum fee, deadline, swap
   checks and liquidity-removal bounds remain enforced. The existing keeper remains trusted for parameters the
   existing AutoExit delegates to it; this adapter does not strengthen those underlying trust assumptions.
4. Clears any remaining exit configuration and NFT approval, closes the registry entry, returns the NFT, and sends
   token0/token1 proceeds to the fixed beneficiary. Native proceeds are wrapped into WETH before payment.

All four steps are one transaction. A failed trigger, swap, recipient callback or settlement restores custody,
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
Beneficiary-initiated `withdraw()` has no added penalty-window or price-trigger restriction; upstream withdrawal
rules still apply, including any reward penalty. The frontend must explain that distinction.

### User withdrawal and remaining rewards

`holder.withdraw()` returns the NFT with its remaining liquidity, clears automation permissions and the old exit
rule, and removes the position from active management. It does not liquidate the LP or require deferred reward
redemption. Contract beneficiaries must implement ERC721 receipt; otherwise NFT delivery reverts atomically.

Immediate balances received by the holder during staking/unstaking remain payable through `claimTokens` or
`claimNative`. Deferred batch claims and root claims have dedicated forwarding functions that always pay the
beneficiary. These functions work after closure. An unfunded or failing deferred claim does not block a separate
principal withdrawal. Other users and operators cannot claim a holder's balances or redirect claim proceeds.
The immutable manager performs the actual deferred-accounting/funding checks; these functions do not manufacture
liabilities or advance funds.

## Tracking

Pin the chain, canonical factory and its immutable NPM. Use `PositionCreated` and `PositionRemoved` plus
`factory.activeHolder(tokenId)` as the active-management source of truth. Zero means the position is no longer
managed. Staking does not remove registration when physical NFT custody changes to a gauge.

`factory.positions(tokenId)` retains the historical holder address solely for claims/recovery and provenance.
Do not interpret that mapping as active membership. After removal, PoolPeach must stop automation and exclude the
position from its active list, while still offering a separate way to recover any rewards owed to the old holder.
`holder.beneficiary()` resolves the end user; the vault's `ownerOf` resolves the holder, not the end user.

## Validation

```bash
# BASE_RPC_URL must be a Base RPC with historical state support; no signing keys are needed.
forge test --match-path 'test/poolpeach/*' -vv
forge fmt --check src/poolpeach/PoolPeachFactory.sol src/poolpeach/PoolPeachPosition.sol \
  test/poolpeach/PoolPeachFactoryFork.t.sol
```

36 tests pass against the actual deployed Aero dependencies at Base block **53168029**. Only the proposed factory
and holders are deployed locally. Coverage includes creation and initial staking, actual keeper staking and consent
revocation, exit execution, penalty policy, manual withdrawal, registry lifecycle, operator revocation, recipient
binding, fee limits, rollback on trigger/slippage/recipient failures, callback reentrancy, root/batch claim forwarding,
cross-holder isolation, residual tokens, native funding and unavailable borrowing/generic-call entrypoints.

Deferred-liability cases seed GaugeManager accounting/storage and funding on the fork, then call its actual claim
functions. They test ownership forwarding and isolation; they do not reproduce upstream delayed minting/redemption.
The suite does not test successful live router swaps, wallet prompts, production keeper scheduling, frontend/indexer
integration or every malicious dependency behavior. Existing protocol dependencies are trusted within their declared
interfaces. These are reproducible regression checks, not an audit or authorization to deploy.

## Before deployment

- Review the new custody layer independently; existing core audits do not cover it.
- Evaluate per-position deployment gas. Clones are deliberately omitted
  from this first draft to avoid adding initialization/proxy complexity.
- Review exit configuration editing, wallet funding UX and any desired ongoing compounding as separate scope.
- Add a reviewed deployment/preflight flow, register the factory once with AutoExit, and validate selected pools.
- Wire beneficiary resolution, active registry indexing, post-closure reward recovery and the factory exit route
  into PoolPeach and its keeper. No frontend, keeper or production configuration is changed by this PR.
