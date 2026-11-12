# Add NVDAc, TSLAc and GOOGLc to the existing Aero vault

This proposal deploys **three immutable StockTwapFeed adapters**, then configures the existing
oracle and vault. The existing V3Oracle, vault, GaugeManager, automators and holders remain in place.
Nothing is activated by merging, deploying the adapters, running the preparation command or running tests.
Only the separately approved owner configuration calls enable collateral.

## Proposed settings

The reviewed settings are in [`config/aero-stock-collateral.json`](../../config/aero-stock-collateral.json).

| Setting | Proposed value |
|---|---|
| Stock collateral factor | 50% (`2147483648 / 2^32`) |
| Per-stock debt exposure limit | 5% of total lender assets (`214748364 / 2^32`, rounded down) |
| Stock oracle mode | `CHAINLINK` (enum 3), with a TWAP-checking adapter as its feed |
| Stock feed maximum age | 86,400 seconds, matching the published heartbeat |
| Adapter TWAP reference | Configured new Aero stock/USDC pool, 60 seconds, 200 basis points |
| Adapter USDC/USD feed maximum age | 86,400 seconds |
| V3Oracle TWAP pool/window | None / zero; stock/USDC verification occurs inside the adapter |
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

## Why an adapter instead of replacing the oracle?

The vault's `oracle` binding is immutable. The existing V3Oracle uses WETH as its reference token,
and its built-in TWAP mode requires a stock/WETH pool. Its per-token **feed address is configurable**.
We therefore deploy one `StockTwapFeed` per stock and install it through `setTokenConfig` in CHAINLINK mode.

Each adapter reads the original stock/USD and USDC/USD Chainlink feeds, validates both rounds, and
compares the implied stock/USDC price to the configured Aero pool's 60-second geometric TWAP.
It returns the **unchanged stock round**, including its USD answer and original timestamps, only when
absolute deviation is at most 2% of the Chainlink-derived stock/USDC price. It never prices collateral
from the pool, substitutes the last good answer, or makes an old feed look fresh. USDC is not assumed
pegged: a $90 stock and $0.90 USDC imply 100 USDC per stock.

The adapter is intentionally restricted to **8-decimal stock tokens, 6-decimal USDC, and two 8-decimal
USD feeds**. It rejects incorrect feed decimals and an incorrect pool pair at construction. Token
metadata and canonical factory resolution are verified by the preparation helper before activation;
B20 metadata cannot be called by standard Foundry's EVM. Do not reuse this adapter for other decimal
layouts or configure it manually without those checks. Token and feed identities remain trusted inputs.

All adapter bindings and parameters are immutable. There is no owner, custody, approval, swap,
callback, setter or TWAP bypass. To change a pool/window/tolerance, deploy a replacement adapter and
have the existing oracle owner explicitly change the token's feed; no vault migration is required.
The preparation helper deliberately rejects conflicting existing settings rather than silently replacing them.

An invalid, nonpositive, zero-timestamp, future-dated or stale underlying round reverts. Insufficient
TWAP history, a pool observation failure or excessive divergence also reverts, propagating to both
borrowing and liquidation. The original position-pool 2% spot guard, USDC/WETH/cbBTC settings and
sequencer checks remain active. The 60-second/2% settings follow the existing collateral policy but
are **not a finding that they are optimal for smoothed stock feeds**.

A TWAP adds independent historical-price verification, but is still manipulable at sufficient cost.
It can also block liquidation during legitimate rapid moves or a prolonged feed/pool divergence.
The configured reference is one stock/USDC pool per stock; eligible collateral can reside in other
Aero pools, whose own spot guards still apply. A 24-hour heartbeat does not immediately distinguish
quiet markets from failed input sources. Retain the stress/liquidity review and outage procedures
as activation prerequisites; do not widen limits automatically to restore availability.

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

After deploying and verifying the adapters, six owner calls, in order:

1. Oracle `setTokenConfig` for each stock: its **adapter address**, age 86400, zero outer TWAP pool/window, mode 3, maxDifference 0. The adapter enforces the independent 60-second/2% check.
2. Vault `setTokenConfig` for each stock: factor `2147483648`, exposure `214748364`.

All three oracle configurations precede any collateral activation. Configuring the oracle alone does not
assign the stock a positive collateral factor. EOA calls are separate transactions, not one atomic batch.
If interrupted, rerun preparation: exact matches are skipped, conflicting settings cause a failure rather
than silently being overwritten. Do not retry an uncertain pending transaction until its receipt/nonce is resolved.

## Deploy and verify only the adapters

The immutable pools are pinned in `config/aero-stock-collateral.json`:

| Stock | New Aero stock/USDC reference pool |
|---|---|
| NVDAc | `0xf668e21993f0acd7ab00bb1cfbaed0df28a3c8ec` |
| TSLAc | `0x7a33000372f3f028f074182ccb9d16cbeefbf920` |
| GOOGLc | `0x16c70f04c3080a127486cdf5a4c33c066bbf47c3` |

USDC/USD feed: `0x7e860098f58bbfc8648a4311b374b1d669a2bc6b` (the existing oracle's USDC feed).

Set `BASE_RPC_URL` to the existing Base RPC. Rehearse without broadcasting:

```bash
forge script script/DeployStockTwapFeeds.s.sol:DeployStockTwapFeeds \
  --rpc-url "$BASE_RPC_URL" --sender 0x83681C14770b44361e21Faf91D8325423365eA5C -vv
```

The script checks all three pool/factory bindings and runs each exact constructor and price check
locally before recording any broadcast. A failed TWAP check is a reason to investigate/wait, not
bypass the validation. No B20 transfers are performed. Once deployment is approved, keep other
Base senders using the deployer account paused and add `--broadcast --slow --account deployer`.
This sends only three contract creations, not oracle/vault configuration. For a partial broadcast,
inspect receipts and use Foundry `--resume` with the original broadcast record; do not blindly rerun
as a fresh deployment. Ownership acceptance is unnecessary: adapters have no privileged owner.

Verify each `src/oracles/StockTwapFeed.sol:StockTwapFeed` deployment on BaseScan using the exact
constructor arguments from `broadcast/DeployStockTwapFeeds.s.sol/8453/run-latest.json` and this
checkout's compiler settings. Record the **confirmed**, verified addresses in an external JSON file:

```json
{
  "NVDAc": "0x<confirmed NVDAc adapter>",
  "TSLAc": "0x<confirmed TSLAc adapter>",
  "GOOGLc": "0x<confirmed GOOGLc adapter>"
}
```

No final addresses are committed because this PR does not deploy. A successful dry-run's predicted
addresses are not evidence of deployment. The preparation helper checks the supplied addresses'
bindings and behavior; it is not a substitute for verified bytecode/source provenance.

## Prepare and simulate (read-only)

From the `lend` checkout, with Python 3, Foundry `cast`, and either `BASE_RPC_URL` or `ALCHEMY_API_KEY` in the environment:

```bash
python3 script/prepare-aero-stock-collateral.py --adapters /tmp/stock-adapters.json --out /tmp/aero-stock-collateral
```

This validates chain/deployment bindings, current authority, token/feed identity, decimals, live positive
feed answers, freshness, unchanged 2% guard, adapter immutables, a successful TWAP-checked round, and unset or already-matching stock configurations. It performs
an actual Base `eth_call` of every pending setter as its owner, including native B20 metadata execution.
It writes `plan.json` with public addresses, a pinned validation block, feeds, owners and unsigned calldata.
It neither unlocks a wallet nor broadcasts. The helper intentionally refuses higher limits without code review.

## Execute after approval and Chainlink confirmation

If the deployer still owns both contracts, keep other Base bots using that account paused during signing,
then run the same helper with explicit broadcast and the local keystore:

```bash
python3 script/prepare-aero-stock-collateral.py --adapters /tmp/stock-adapters.json --out /tmp/aero-stock-collateral --broadcast --account deployer
```

The helper redoes preflight, verifies the keystore's public address, sends only missing calls in order,
waits for receipts, and stops on failure. No private key or password belongs in configuration files.

If both owners have become the Safe, preparation additionally writes `safe-batch.json` for Safe Transaction
Builder. Import and review the ordered six calls before signing/executing through the Safe. Direct EOA
broadcast is disabled in this ownership state. If only one contract has moved to the Safe, complete the
intended ownership handoff before preparing the single Safe batch; do not use the old deployer plan blindly.

After execution, rerun preparation without `--broadcast`. Expect **zero remaining configuration calls**.
Verify the exact proposed feed/mode/factors, preserved existing collateral, and unchanged pool guard.
The three new adapters require source verification; existing contracts do not need re-verification.

## Validation and remaining launch work

Adapter validation at Base block **56276522**:

- 13 unit tests passed (including 256 fuzz cases): conversion, token ordering, divergence in both
  directions, negative tick rounding, accumulator wrap, age boundaries, invalid rounds and missing history.
- Six fork tests passed through the existing oracle/vault, preserving existing collateral settings.
- The deployment script dry-run produced only three adapter creations and passed all preflight checks.
- Native Base `eth_call` simulations of all three constructors, adapter rounds and all six owner setters
  passed. Adapter runtime code was installed through temporary RPC state overrides only; B20 metadata
  was executed natively without shims. The full preparation CLI also passed with those simulated adapters.
- Runtime size: 4,112 bytes per adapter. No existing contract bytecode changes.

No contracts were deployed or collateral enabled. Repeat the preparation command using confirmed,
verified adapter addresses after deployment. Simulations do not establish full liquidation execution.

Run the focused fork tests with `BASE_RPC_URL` set to an archive-capable Base endpoint:

```bash
forge test --match-path test/fork/AeroStockCollateral.t.sol \
  --fork-url "$BASE_RPC_URL" --fork-block-number 56276522 -vv
```

The fork tests rehearse the setter sequence against existing contracts, preserve USDC/WETH/cbBTC settings,
and check unauthorized activation, stale feed rejection, TWAP disagreement, unchanged underlying rounds,
and the retained position-pool divergence guard.
B20 metadata is native to Base; stock Foundry cannot execute it. The tests shim **only stock decimals()**.
The position-price test supplies a synthetic NFT's metadata but uses the real pool, factory and feeds.
These tests do not establish a full B20 transfer/borrow/liquidation rehearsal. The independent Base `eth_call`
preflight executes each actual setter without those shims, once real adapter addresses exist.

Before activation: confirm Chainlink support; evaluate GOOGLc/TSLAc pool liquidity and divergence history,
not just NVDAc; review market-shock and feed-outage scenarios against the proposed limits; confirm bot/indexer/UI
support and gauge registration for intended staked positions; and rehearse the real B20 borrowing/repayment/
liquidation flow in a Base-native simulation or controlled test. Those are not completed by this PR.

Merging this configuration proposal is separate from approving its production execution. Do not add these
assets to the default fresh-stack deployment script silently; this is an explicit opt-in for the existing vault.
