# Risk Model And Acceptability Rules

This document is for agents/reviewers making code or design changes.

## 1) Health And Borrow Safety

Core health relation:

- healthy if collateral value >= debt

Implementation details:

- Collateral value uses oracle valuation and per-token collateral factors.
- Vault uses an additional borrow safety buffer (`BORROW_SAFETY_BUFFER_X32 = 95%`) for debt-increasing operations.
- Liquidation eligibility uses direct health (without borrow buffer).

Practical implication:

- A borrow can fail even before the position is strictly liquidatable.

## 2) Liquidation Behavior

Key bounds:

- Min liquidation penalty: 2%
- Max liquidation penalty: 10%

Normal liquidation:

- Value is sourced from uncollected fees first, then principal liquidity.
- Debt + penalty are covered and residual NFT value remains with position owner.

Underwater liquidation:

- If position value < debt, reserves can cover shortfall.
- If reserves are insufficient, vault can reduce lend exchange rate (socialized lender loss).

### Oracle-Failure Policy (Intentional, Fail-Closed)

When oracle verification fails, valuation-gated operations are intentionally blocked.

- If `oracle.getValue(...)` cannot produce a trusted value (for example `PriceDifferenceExceeded`, stale/invalid feed data, or sequencer safety checks), health checks revert.
- As a result, new debt issuance is blocked (`borrow`, debt-increasing transform paths), and liquidation is also blocked until oracle checks pass again.
- This is an explicit safety design choice to avoid issuing debt or executing liquidation with untrusted pricing.
- Exception: debt-free transform paths may skip health/oracle checks per `NFT_PATH_ATLAS.md` design notes.

## 3) Rate Accrual And Solvency Accounting

Global accrual:

- Debt and lend exchange rates update based on elapsed time and rates from `InterestRateModel`.
- Borrow and supply rates are utilization-based.

Reserve mechanics:

- Reserve factor skims part of spread between borrow and supply accrual.
- Reserve protection factor enforces a minimum retained reserve buffer on withdrawals.

## 4) Limits And Circuit-Breakers

Hard-coded / enforced mechanisms:

- Max collateral factor allowed by config: 90%
- Global lend limit
- Global debt limit
- Daily lend increase limit (max 10% of lent base, with min floor)
- Daily debt increase limit (max 10% of lent base, with min floor)
- Per-token collateral exposure limit (`collateralValueLimitFactorX32`)

These are critical protocol safety rails; bypasses are not acceptable.


Recommended high-signal test files:

- `test/atlas/AtlasTransitions.t.sol`
- `test/audit/AuditProperties.t.sol`
- `test/integration/aerodrome/GaugeManagerVulnerability.t.sol`
