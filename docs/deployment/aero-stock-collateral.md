# Optional stocks on a fresh USDC-reference Aero vault

This is the fresh-deployment alternative to the adapter proposal. Deploy the **unchanged** V3Oracle
with USDC as reference, using the [USDC-reference deployment runbook](aero-usdc-reference.md), then
configure stock feeds through its existing CHAINLINK_TWAP_VERIFY mode. No StockTwapFeed adapters
are deployed. The old WETH-reference oracle cannot accept this configuration.

## Reviewed proposal

| Setting | Value |
|---|---|
| Stock collateral factor | 50% |
| Per-stock debt exposure limit | 5% of lender assets, not a fixed USDC cap |
| Stock mode | CHAINLINK_TWAP_VERIFY (1) |
| Stock USD feed maximum age | 86,400 seconds |
| Independent reference | Each stock's configured Aero stock/USDC pool |
| Reference TWAP | 60 seconds; 200 basis points |
| Actual position-pool spot divergence guard | 200 basis points, unchanged |

Exact source feeds, tokens and pools are in `config/aero-stock-collateral.json`. The new vault and
oracle addresses are deliberately absent: supply confirmed addresses from the completed deployment,
not dry-run predictions. The helper verifies the vault/oracle binding, Base NPM/factory, USDC asset
and reference, owners, token/feed identities, canonical pool resolution and observation history.

Every loan's full debt counts against both tokens' exposure limits. The lower token collateral factor
applies to the whole position. These are token-level settings across eligible Aero pools, not a pool
allowlist. The reference TWAP pool and the actual collateral pool can be different; both price checks
must pass. A 5% exposure admission limit can be exceeded later through interest or lender withdrawals.

Stock price conversion divides the stock/USD Chainlink answer by the USDC/USD answer, accounting
for 8-decimal stock and 6-decimal USDC units. It does not assume USDC/USD equals one. Disagreement,
stale feeds, unavailable observations or a sequencer failure can block borrowing **and liquidation**.
The 60-second/2% policy requires stress and availability review for smoothed 24/7 feeds; it is not
proof of safety. Debt-free Poolside positions do not require lending eligibility.

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

## Two-stage preparation and activation

After completing deployment verification and ownership handoff, substitute confirmed fresh addresses:

```bash
python3 script/prepare-aero-stock-collateral.py \
  --vault <fresh-vault> --oracle <fresh-oracle> --out /tmp/aero-stock-feeds
```

Without `--enable-collateral`, the plan contains only missing oracle configurations. Three calls
install the stock/USD feeds with their stock/USDC pools, mode 1, window 60, tolerance 200, age 86400.
This does not enable stock borrowing. A different existing configuration is rejected rather than overwritten.

After explicit configuration approval, the generated Safe batch can execute the calls if both contracts
are Safe-owned. If still deployer-owned, add `--broadcast --account deployer`; keep Base bots sharing that
account paused until all sends are confirmed. The helper verifies every receipt and stops on failure.
Rerunning skips exact installed settings. Do not blindly retry an uncertain pending transaction.

Then prepare collateral activation separately:

```bash
python3 script/prepare-aero-stock-collateral.py \
  --vault <fresh-vault> --oracle <fresh-oracle> --enable-collateral --out /tmp/aero-stock-activation
```

This requires all three oracle settings to be installed exactly and **live `getTokenValue` calls to pass**
before generating the three vault collateral calls. A failing TWAP check is a reason to investigate/wait,
not bypass the check. Execute only after the stock activation prerequisites are approved. The same Safe
or explicit deployer-broadcast paths apply. Borrowing also requires the vault-wide debt cap to be enabled.

The initial ownership/borrowing handoff from `prepare-aero-safe.py` deliberately allows only the three
basic assets. Run it **before** adding stock feed/asset configuration. Stock activation is a separate
reviewed change, not something to conceal from the initial deployment validator.

## Validation boundaries

Fork tests deploy a fresh USDC-reference oracle and vault, configure the exact stock/USDC pools and
check valuation, feed staleness, TWAP disagreement and the retained position-pool guard. Only B20
`decimals()` is shimmed because standard Foundry does not implement native Base B20 metadata. Synthetic
NFT metadata tests valuation; it is not a full real stock-token transfer/borrow/liquidation rehearsal.

```bash
forge test --match-path test/fork/AeroStockCollateral.t.sol \
  --fork-url "$BASE_RPC_URL" --fork-block-number 56276522 -vv
```

Before activating stocks: obtain Chainlink confirmation for the exact proxies; finish liquidity,
price-divergence, market-shock and feed-outage review; confirm bot/indexer/UI readiness; and rehearse
real B20 borrowing/repayment/liquidation in a Base-native simulation or controlled test. The fresh basic
asset deployment and its tests do not eliminate those stock-specific prerequisites.
