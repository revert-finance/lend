# Add NVDAc, TSLAc and GOOGLc to the existing Aero vault

This is a **configuration-only proposal** against the `aero` release. No contract, oracle adapter,
vault, GaugeManager, automator, Poolside holder or factory needs deploying. No source in `src/`
is changed. Nothing is activated by merging this PR, running the preparation command or running tests.

## Proposed settings

The reviewed settings are in [`config/aero-stock-collateral.json`](../../config/aero-stock-collateral.json).

| Setting | Proposed value |
|---|---|
| Stock collateral factor | 50% (`2147483648 / 2^32`) |
| Per-stock debt exposure limit | 5% of total lender assets (`214748364 / 2^32`, rounded down) |
| Stock oracle mode | `CHAINLINK` (enum 3) |
| Stock feed maximum age | 86,400 seconds, matching the published heartbeat |
| Stock TWAP reference pool/window | None / zero |
| Existing position-pool deviation limit | Preserve 200 basis points |
| USDC, WETH and cbBTC settings | Preserve current values |
| Global/daily lending and borrowing limits | Preserve current values |

The per-stock limit is **not a fixed USDC cap**. With $1 million of lender assets, it allows
approximately $50,000 of debt backed by positions containing each stock; with $100,000, about $5,000.
Every loan's full debt counts toward both tokens' limits, including loans in a stock/USDC pair.
Across three stocks this permits at most roughly 15% of lender assets at new-debt admission,
with overlap for stock/stock loans. Interest and lender withdrawals can move existing exposures above
the admission limit; this is not an invariant enforced continuously or an automatic liquidation trigger.

The position uses the **lower collateral factor of its two tokens**, applied to the whole LP value.
A stock/USDC position therefore uses 50%, including when mostly USDC. The additional 95% borrowing
buffer makes ordinary new-borrow capacity approximately 47.5% of oracle-valued LP assets before other limits.
The 50% factor is not a promise of tolerating a 50% market crash: LP composition, liquidation costs,
oracle lag, available liquidity and continued price moves all matter.

These settings admit eligible positions containing the tokens across the configured Aero factory;
they are **not a per-pool allowlist**. Gauge registration is separate. Use the existing gauge-sync
runbook for newly created gauges; this proposal does not grant additional operators or change staking consent.
Existing debt-free Poolside positions do not need to migrate or start borrowing.

## Why no adapter or new oracle deployment?

The Coinbase 24/7 feeds expose the `AggregatorV3Interface` already consumed by `V3Oracle` and include
Coinbase's share-per-token multiplier. Their answers value the exact Coinbase B20 token, not an arbitrary
issuer's wrapper with the same equity ticker.

The current oracle's immutable reference token is WETH. Its optional token-level TWAP verification
requires a token/WETH reference pool. This proposal uses `CHAINLINK` for the stock token so it does not
add a dependency on a thin stock/WETH pool. **This differs from cbBTC's CHAINLINK_TWAP_VERIFY mode**:
there is no separate stock/WETH 60-second TWAP check. However, `V3Oracle._populatePrices` still compares
each actual collateral position's pool spot ratio with its oracle-derived ratio, using the unchanged
2% global guard. Existing USDC TWAP and sequencer checks also remain in effect.

When that guard or freshness checks fail, valuation-gated borrowing **and liquidation** revert.
There is no fallback to a pool-only price, no automatic feed switching, and no widened tolerance.
A 24-hour heartbeat also means feed age alone cannot immediately distinguish a quiet market from a
failed off-hours data source. We need operating procedures and collateral buffers for delayed or absent updates.

## Dependencies and provenance (checked November 12, 2026)

| Asset | Coinbase B20 token | Chainlink 24/7 proxy on Base |
|---|---|---|
| NVDAc | `0xb20000000000000000000078ee7ce2fe4908108c` | `0x48d9731af6cc55b879fe76a4bd1a6c2c0bdaf944` |
| TSLAc | `0xb2000000000000000000001e800a7f5189430cd0` | `0xa5ccd0315346b9a8a1d0afecd7cc4e820e405e96` |
| GOOGLc | `0xb2000000000000000000002d0ba3164cc74f58b7` | `0xdd9b9ec942477aa672a15adf91ac5089bd86cd85` |

- [Chainlink Base feed directory](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json):
  exact proxies, `Coinbase ... (24/7)` descriptions, 8 decimals, 0.5% update deviation, 86,400-second heartbeat.
- [24/7 methodology and integration requirements](https://docs.chain.link/data-feeds/tokenized-equity-feeds/24-7).
- [Coinbase token valuation/multiplier methodology](https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase).
- Exact token addresses match the existing Coinbase token catalog and were checked with native Base
  `symbol()` and `decimals()` reads. Symbols alone are not the source of token identity.

The entries carried `hidden: true` in the directory when checked. Chainlink explicitly requires contact
before integration. Confirm production support for these exact proxies and tokens before activation.
That confirmation is an outstanding operational prerequisite, not a code deployment requirement.

## Accounts and operations

Target vault: `0x4a315e98d87c049b92e31a677a4dec63f4ef8f7f`.
Target oracle: `0x860ee1eaac61ad4ac761cb5c0046be22ecbc7c1f`.

At the checked snapshot, both are owned by deployer `0x83681c14770b44361e21faf91d8325423365ea5c`,
with pending owner Safe `0x45b220860a39f717dc7daff4fc08b69cb89d1cc9`.
These setters are owner-only and have no built-in timelock. Pending ownership alone gives the Safe no authority.
The helper rechecks actual ownership; it does not accept ownership or nominate another owner.

Six calls, in order:

1. Oracle `setTokenConfig` for each stock: its 24/7 feed, age 86400, zero TWAP pool/window, mode 3, maxDifference 0.
2. Vault `setTokenConfig` for each stock: factor `2147483648`, exposure `214748364`.

All three oracle configurations precede any collateral activation. Configuring the oracle alone does not
assign the stock a positive collateral factor. EOA calls are separate transactions, not one atomic batch.
If interrupted, rerun preparation: exact matches are skipped, conflicting settings cause a failure rather
than silently being overwritten. Do not retry an uncertain pending transaction until its receipt/nonce is resolved.

## Prepare and simulate (read-only)

From the `lend` checkout, with Python 3, Foundry `cast`, and either `BASE_RPC_URL` or `ALCHEMY_API_KEY` in the environment:

```bash
python3 script/prepare-aero-stock-collateral.py --out /tmp/aero-stock-collateral
```

This validates chain/deployment bindings, current authority, token/feed identity, decimals, live positive
feed answers, freshness, unchanged 2% guard, and unset or already-matching stock configurations. It performs
an actual Base `eth_call` of every pending setter as its owner, including native B20 metadata execution.
It writes `plan.json` with public addresses, a pinned validation block, feeds, owners and unsigned calldata.
It neither unlocks a wallet nor broadcasts. The helper intentionally refuses higher limits without code review.

## Execute after approval and Chainlink confirmation

If the deployer still owns both contracts, keep other Base bots using that account paused during signing,
then run the same helper with explicit broadcast and the local keystore:

```bash
python3 script/prepare-aero-stock-collateral.py --out /tmp/aero-stock-collateral --broadcast --account deployer
```

The helper redoes preflight, verifies the keystore's public address, sends only missing calls in order,
waits for receipts, and stops on failure. No private key or password belongs in configuration files.

If both owners have become the Safe, preparation additionally writes `safe-batch.json` for Safe Transaction
Builder. Import and review the ordered six calls before signing/executing through the Safe. Direct EOA
broadcast is disabled in this ownership state. If only one contract has moved to the Safe, complete the
intended ownership handoff before preparing the single Safe batch; do not use the old deployer plan blindly.

After execution, rerun preparation without `--broadcast`. Expect **zero remaining configuration calls**.
Verify the exact proposed feed/mode/factors, preserved existing collateral, and unchanged pool guard.
No block-explorer source verification is needed: no new code is deployed.

## Validation and remaining launch work

Validated at Base block **56263482**: all six native Base setter simulations passed; all four focused
fork tests passed (configuration/preservation, authorization, stale feed, and retained divergence guard).

Run the focused fork tests with `BASE_RPC_URL` set to an archive-capable Base endpoint:

```bash
forge test --match-path test/fork/AeroStockCollateral.t.sol \
  --fork-url "$BASE_RPC_URL" --fork-block-number 56263482 -vv
```

The fork tests rehearse the setter sequence against existing contracts, preserve USDC/WETH/cbBTC settings,
and check unauthorized activation, stale feed rejection and the retained position-pool divergence guard.
B20 metadata is native to Base; stock Foundry cannot execute it. The tests shim **only stock decimals()**.
The position-price test supplies a synthetic NFT's metadata but uses the real pool, factory and feeds.
These tests do not establish a full B20 transfer/borrow/liquidation rehearsal. The independent Base `eth_call`
preflight executes each actual setter without those shims.

Before activation: confirm Chainlink support; evaluate GOOGLc/TSLAc pool liquidity and divergence history,
not just NVDAc; review market-shock and feed-outage scenarios against the proposed limits; confirm bot/indexer/UI
support and gauge registration for intended staked positions; and rehearse the real B20 borrowing/repayment/
liquidation flow in a Base-native simulation or controlled test. Those are not completed by this PR.

Merging this configuration proposal is separate from approving its production execution. Do not add these
assets to the default fresh-stack deployment script silently; this is an explicit opt-in for the existing vault.
