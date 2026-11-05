# Aero compound carry-forward

## Purpose and reference behavior

A successful fee or reward compound may only reinvest part of its inputs. Retain the unused amounts for the
same position's next compound instead of sending them to the holder to sit idle. This follows Revert's existing
Uniswap `AutoCompound` accounting (`positionBalances`, separate protocol balance under token ID zero, fee on
actual liquidity additions, owner withdrawal). It does not impose a new minimum-reinvestment outcome or change
TWAP failure behavior. The selling range is unchanged during compounding.

Reference source: [Revert Uniswap AutoCompound](https://github.com/revert-finance/lend/blob/7e85a81ac97663a3a731f6d6f07f14d774962a6e/src/transformers/AutoCompound.sol),
checked against the deployed bot artifact source hash `0x7d4dc2004f98b86b6b412a33cf30d8e3d3b1c2128f2fe6639035a2982c7523e3`.

## Custody, accounting and fees

AutoRangeAndCompound holds the single `positionBalances(tokenId, token)` ledger and its backing ERC20 tokens.
`CompoundBalanceLib` is a fixed linked library, not another custodian or an upgradeable implementation.
Its calls execute in the caller's context. Tokens and storage do not reside in the library.

Fee compounding adds previously saved token0/token1 to newly collected fees. Owner-configured minimum fresh-fee
thresholds retain their meaning. The original fee formula is unchanged: maximum addition is
`available * Q64 / (Q64 + rate)`; the fee is `actuallyAdded * rate / Q64`. Only actually added liquidity is charged.
Unused balances have not paid this fee; charging them when eventually added does not charge twice.
Before adding, the linked library uses the NPM's standard `LiquidityAmounts` math and current pool price to
skip a zero-liquidity mint. This matters when the fee step immediately revisits reward-compound dust in the
same transaction: retained dust must not roll back the preceding compound or staking switch. No fee is charged
on a skipped addition. Nonzero-liquidity mint failures still revert; this is not a minimum-value/outcome rule.

GaugeManager has an optional **one-time** `compoundBalanceSource` binding. The fresh deployment binds it to
AutoRangeAndCompound. An unbound manager retains its old payout behavior. This binding is separate from the
owner-adjustable fee-mode source, so changing the fee-rate provider cannot abandon the ledger.

During reward compounding the manager claims fresh rewards, checks the fresh-reward minimum, then draws that
position's saved pool tokens and receipt tokens. It swaps available receipts, combines the saved pool tokens
with the outputs, adds liquidity, and returns unspent inputs to the ledger. A receipt token that is also a pool
token is drawn once and reused as that pool token. A call with no fresh rewards can reinvest saved funds when
the fresh-reward minimum permits it. `RewardsCompounded.aeroAmount` and the returned `aeroAmount` continue to mean
freshly claimed emissions, excluding recycled receipts.

The ledger's manager entrypoint verifies the registered vault, its configured GaugeManager, the common NPM,
the manager's balance-source binding, and an active position-to-gauge mapping. Tokens come from NPM metadata
and the manager's receipt token; callers cannot supply arbitrary assets or beneficiaries. Credits pull the
specified tokens and require exact received amounts. Temporary allowances are cleared. All operations roll
back together on failure. Fee-on-transfer/rebasing assets are not supported by this accounting.

AutoRange's withdrawer can withdraw only ledger account zero, including separately recorded range-change
protocol fees. GaugeManager retains only its protocol fees after settlement; its existing deferred-reward
reserve exclusions remain intact. Saved balances are not included in lending collateral valuation.

As in the Uniswap `AutoCompound` reference, arbitrary ERC20 transfers/donations into AutoRange are not
credited to account zero or any user and cannot be recovered by its withdrawer. Do not send tokens directly
to the automator. This deliberately replaces the old AutoRange sweep-all behavior; normal compound and
range-change protocol fees remain withdrawable. General surplus recovery would need aggregate user-liability
tracking and is outside this minimal port. Native ETH recovery remains unchanged.

## Ownership and position lifecycle

Saved compound balances follow the NFT's current economic owner, matching the Uniswap ledger model. This is
separate from deferred emissions, which retain their existing historical owner binding. A vault's owner record
resolves vaulted and staked ownership; a wallet-held NFT uses its current NPM owner. Only that owner can call
`withdrawLeftoverBalances(tokenId, recipient)`, including while staked without changing gauge custody when that vault is recorded by configuration or compounding.
A wallet position moved manually into another vault should be reconfigured for that vault before staking;
otherwise the old ledger may need NFT exit to resolve its owner. Poolside creation and operator-managed
staking record the vault automatically.

A same-pair replacement moves saved balances to the replacement NFT and clears the old ID. Direct AutoRange
replacement and the existing authenticated vault replacement callback cover both paths. A replacement changing
the pair returns the saved assets to the old economic owner instead of attaching incompatible assets to the
new pair. The callback uses cached asset identities so a transformer burning the old NFT does not erase the
ability to settle its saved tokens. Custom vaults must install this automator as their staking policy if they
want its generic replacement callback; the deployment script already does so.

NFT transfers carry saved balances with the NFT. Wallet users must withdraw balances before manually burning
an empty NFT; the ledger does not invent a recoverable owner after an arbitrary external burn. Poolside's exits
retrieve balances before returning or retaining its NFT. Available pool tokens and receipts are paid to the
fixed beneficiary on manual and automated exits; untradeable dust is returned in kind and not trapped.

This PR does not incorporate #113's leftover-to-USDC swaps. `withdrawToAsset` continues to swap the position
through V3Utils and return existing/saved balances in kind; its minimum applies to the NFT sale. Deferred rewards
remain independently claimable after closure. Gauge deposit/withdrawal-time proceeds retain their existing
payout rules rather than being silently added to a different owner's carry-forward balance.

## Keeper / integrator changes

The bot selector remains `0xd403dcda`:
`autoCompoundWithVaultAndRewardCompound((uint256,bool,uint256,uint256),address,(uint256,uint256,uint256,uint8))`.

- Read `positionBalances(tokenId, token0/token1/receipt)` when sizing compounds. Deduplicate a receipt that is
  also a pool token. Do not treat carried balances as newly earned income in APY/profitability accounting.
- Saved pair tokens participate in the reward add-liquidity step before the fee step. Account for those assets
  when planning receipt splits and the subsequent fee swap; simulate the complete existing bot entrypoint.
- The contract preserves fresh-fee/reward minimums, swap limits, penalties, consent and cooldowns. A swap skipped
  on TWAP failure can still leave balances for a later attempt; this change guarantees retention, not efficiency.
- Zero-fresh-fee retries are possible with zero configured minima, but keepers should avoid repeatedly spending
  gas on unchanged rounding dust. This contract PR does not update the bot implementation.

## Deployment and review scope

Existing contracts are immutable. Use a fresh suite and Poolside factory; existing positions are tests and this
PR does not migrate them. `DeployAeroProtocol` binds the manager's balance source; Safe preparation checks it.
Foundry links `CompoundBalanceLib` and the existing `VaultLib` and `AeroRewardDelivery` libraries. The latter's
validation body is unchanged; making it external avoids inlining it into GaugeManager. Verification includes
all three libraries. Initial debt limits and ownership activation remain separate and unchanged.

Existing liquidity-addition, owner/withdrawal bookkeeping and staking preparation code is moved into linked
libraries to meet EIP-170; this is an explicit review surface. No new price oracle, configurable outcome
threshold, user fee, or upgrade authority is introduced. No production transactions are executed by this PR.

## Validation

Production build: Solidity 0.8.24, optimizer 25 runs, viaIR; unchanged settings.

| Contract/library | Runtime bytes | EIP-170 headroom |
|---|---:|---:|
| AutoRangeAndCompound | 24,424 | 152 |
| GaugeManager | 23,463 | 1,113 |
| CompoundBalanceLib | 10,542 | 14,034 |
| VaultLib | 6,835 | 17,741 |
| AeroRewardDelivery | 1,641 | 22,935 |
| PoolsideFactory | 21,875 | 2,701 |

The fresh deployment dry-run at Base block 53,136,369 succeeds and records 13 creations (ten contracts and
three libraries). These are simulation results, not deployed addresses. AutoRange has little size headroom.

All 449 tests across 37 unit, Aero integration, Poolside and Base-fork suites pass:

```sh
forge build --root fixtures/upstream-gauge
BASE_RPC_URL=<archive Base RPC> forge test \
  --match-path 'test/{unit,integration/aerodrome,poolside,fork}/**' --code-size-limit 1000000
forge build --skip test --skip script --sizes
AERO_FORK_BLOCK=53136369 bash script/deploy-aero-protocol.sh --dry-run
```

Focused tests cover
fee and reward reuse, fee charging, fresh reward minimums, receipt/pool-token overlap, partial reward fills,
withdrawer exclusion, cross-position isolation, unauthorized/unfunded credits, failure rollback, staked claims,
NFT transfers/replacements and holder exits. Existing Base-fork, root-delivery, route-slippage and staking
regressions remain required. Test harnesses need an increased size limit because they embed contract creation
code; production runtime assertions and `forge build --skip test --skip script --sizes` use the actual limits.
