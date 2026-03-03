# Protocol Primer (Whitepaper -> Code)

This is a concise map from the Revert Lend whitepaper to this repository's implementation.

## 1) What The Protocol Does

Revert Lend is a peer-to-pool lending protocol for concentrated-liquidity LP NFTs.

- Lenders deposit one ERC20 lending asset into a shared ERC-4626 vault and receive ERC20 shares.
- Borrowers deposit LP position NFTs as collateral and can borrow the vault lending asset.
- Positions remain managed by users (liquidity changes, fee collection, transforms), subject to health constraints.

In this fork, core contracts are:

- Vault: `src/V3Vault.sol`
- Oracle: `src/V3Oracle.sol`
- Interest model: `src/InterestRateModel.sol`
- Aerodrome staking adapter: `src/GaugeManager.sol`
- One-time GaugeManager binding and its operational risk classification are documented in `docs/agents/risk-and-acceptability.md`.

## 2) Lending Side

The vault is ERC-4626 + ERC-20 share token behavior:

- Deposit/mint: `deposit`, `mint`
- Withdraw/redeem: `withdraw`, `redeem`
- Share value appreciates as borrower interest accrues.

Implementation notes:

- `V3Vault` share decimals match lending asset decimals.
- Exchange rates are tracked globally (`lastDebtExchangeRateX96`, `lastLendExchangeRateX96`).
- Lending asset compatibility assumptions (standard ERC20 only; no fee-on-transfer/rebasing/callback-token semantics) are defined in `docs/agents/risk-and-acceptability.md`.

## 3) Borrowing Side

Borrow flow is NFT-backed:

1. Deposit NFT collateral (`create`).
2. Borrow lending asset (`borrow`).
3. Repay by assets or shares (`repay`).
4. Withdraw collateral only when debt is zero (`remove`).

Collateral logic:

- Position collateral factor = min(collateral factor of token0, token1).
- Per-position debt is tracked as debt shares.
- Health checks are based on oracle collateral value vs debt.

## 4) Unified Liquidity Model

The protocol uses one shared lending pool for all approved collateral types (single market structure):

- Better capital aggregation than isolated pools.
- Risk segmentation is done with per-token collateral configs and collateral exposure limits, not isolated borrow markets.

## 5) Position Management And Transformers

Transformers are protocol-allowlisted contracts that can mutate positions while preserving vault accounting.

- Owner and approved delegates can trigger transforms (`approveTransform`, `transform`).
- `transform()` handles both staked and unstaked positions: it auto-unstakes before the transform and restakes afterward if the position was originally staked.
- Some transformers (e.g., `AutoRangeAndCompound`) replace the position NFT — the old token is burned and a new token ID is minted. When this happens through `V3Vault.transform()`, the vault updates its loan and ownership mappings to the new token ID. Any path that replaces a token without going through vault transform entrypoints (`transform` / `transformWithRewardCompound`) must either update vault state or be blocked, otherwise the vault's loan tracks a dead token.

The transformer set is closed: only the contracts in `src/transformers/` (V3Utils, AutoRangeAndCompound, LeverageTransformer) will ever be whitelisted. Each is included in audit scope and individually reviewed. No third-party or future transformers will be added without a dedicated audit.

See `docs/agents/aerodrome-staking-and-gauge-manager.md` for custody paths and state synchronization invariants.

## 6) Liquidations (Conceptual)

A position becomes liquidatable when debt exceeds collateral capacity.

- Liquidator repays debt and receives a liquidation incentive.
- Penalty is progressive between minimum and maximum bounds.
- If position value is below debt, reserves may absorb loss; if reserves are insufficient, lenders can be socialized via exchange-rate reduction.

This behavior is implemented in `V3Vault.liquidate` and related internal methods.

## 7) Interest Rate Model

Borrow/supply rates are utilization-based (kink model), similar to Compound-style piecewise rate curves.

- Utilization ~ debt / (cash + debt)
- Below kink: base + linear slope
- Above kink: steeper jump slope
- Supply rate is utilization-scaled borrow rate, with reserve factor applied

Implementation lives in `src/InterestRateModel.sol` and vault exchange rate accrual in `V3Vault._calculateGlobalInterest`.

## 8) Oracle Design

Whitepaper model: dual-source pricing (Chainlink + AMM TWAP) with safety checks.

Implementation (`V3Oracle`) supports modes per token:

- `CHAINLINK_TWAP_VERIFY`
- `TWAP_CHAINLINK_VERIFY`
- `CHAINLINK`
- `TWAP`

It also enforces max-difference checks and pool-price sanity checks.

Operational consequence (intended):

- Oracle verification is fail-closed for valuation-dependent flows.
- If oracle checks fail, the protocol blocks new borrowing and blocks liquidation until checks pass again.
- This trades temporary liveness for pricing safety under manipulated or invalid market data.

## 9) Governance Controls (Owner / Emergency Admin)

High-impact configurable parameters:

- Vault limits and risk knobs (`setLimits`, `setTokenConfig`, reserve knobs)
- Transformer allowlist (`setTransformer`)
- Oracle per-token config and mode (`setTokenConfig`, `setOracleMode`)
- Interest model curve params (`setValues`)

Whitepaper framing is governance evolution; code uses on-chain owner/emergency-admin permissions.
