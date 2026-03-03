# Risk Model And Acceptability Rules

This document is for agents/reviewers making code or design changes.

## 1) Health And Borrow Safety

Core health relation:

- healthy if collateral value >= debt

Implementation details:

- Collateral value uses oracle valuation and per-token collateral factors.
- Vault uses an additional borrow safety buffer (`BORROW_SAFETY_BUFFER_X32 = 95%`) for debt-increasing operations.
- Liquidation eligibility uses direct health (without borrow buffer).

Practical implications:

- A borrow can fail even before the position is strictly liquidatable.
- During `transform()`, if debt did not increase, the borrow safety buffer is intentionally skipped. This allows legitimate position adjustments (range changes, compounding) near utilization boundaries. The full health check is still enforced — positions remain overcollateralized, just without the extra 5% margin. This is by design.

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

### Free Liquidation Branch (Intentional, by Design)

When a position is extremely underwater (`fullValue <= penalty`), `_calculateLiquidation` intentionally sets `liquidatorCost = 0`. The remaining debt is covered by reserves or socialized to lenders via lend exchange-rate reduction.

This is deliberate economic design:
- The collateral is worth less than the penalty alone — no rational actor would pay to liquidate.
- Setting `liquidatorCost = 0` incentivizes anyone to clean up bad debt positions rather than leaving them as zombie loans.
- The loss to the protocol/lenders already exists the moment the position went underwater — free liquidation simply resolves the accounting.
- This is a standard pattern in lending protocols (Aave, Compound use similar mechanics for deeply underwater positions).

Reviewer guidance:
- Findings about the existence of the `liquidatorCost == 0` branch, or that liquidators can execute without paying, should be classified as accepted design behavior, not a vulnerability.
- Findings about bugs in the reserve-socialization math or lend exchange-rate reduction within this branch remain in scope.

### Oracle-Failure Policy (Intentional, Fail-Closed)

When oracle verification fails, valuation-gated operations are intentionally blocked.

- If `oracle.getValue(...)` cannot produce a trusted value (for example `PriceDifferenceExceeded`, stale/invalid feed data, or sequencer safety checks), health checks revert.
- As a result, new debt issuance is blocked (`borrow`, debt-increasing transform paths), and liquidation is also blocked until oracle checks pass again.
- This is an explicit safety design choice to avoid issuing debt or executing liquidation with untrusted pricing.
- Exception: debt-free transform paths may skip health/oracle checks (see `V3Vault._requireLoanIsHealthy` which only applies borrow buffer when debt increased).

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

## 5) Lending Asset Compatibility (Hard Assumption)

The vault `asset` is immutable per deployment and is a trusted deployment-time choice.

Supported lending asset behavior:

- Standard ERC20 transfer semantics (exact-in/exact-out accounting).
- No fee-on-transfer / transfer-tax behavior.
- No rebasing / balance mutation outside direct transfers.
- No callback-capable or adversarial transfer hooks that can reenter vault flows.

Reviewer guidance:

- Findings that require violating the above asset assumptions (for example, fee-on-transfer accounting drift or callback-token reentrancy during `transferFrom`) should be classified as deployment misconfiguration / out-of-policy assumptions, not core protocol bugs.
- This includes ALL reentrancy paths that depend on the lending asset executing a callback during transfer — e.g., reentrancy during `_pullAssetFromSender` in `repay`, `liquidate`, `deposit`, or any other vault flow. With a standard ERC20 lending asset, these callbacks cannot occur.
- If deployment policy changes to support such assets, these classes become in-scope and require explicit code hardening.

## 6) External Gauge Dependency (Accepted Risk)

Staked positions depend on the external Aerodrome gauge to return the NFT via `withdraw()`. If the gauge reverts on withdraw (e.g., paused, broken, or upgraded), the vault cannot retrieve the NFT and therefore cannot liquidate that position.

This is an inherent dependency on the external gauge contract — there is no mitigation the vault can implement. The vault cannot liquidate collateral it does not hold. This is accepted as a deployment-time trust assumption: only gauges validated via `setGauge()` (which checks `pool.gauge() == gauge`) are configured, and Aerodrome gauge contracts are trusted external infrastructure.

This acceptance covers ONLY the case where the Aerodrome gauge contract itself
malfunctions. It does NOT cover bugs in the vault's unstake flow, state
desynchronization between vault staking records and gauge state, or reentrancy
during unstake. Findings about the vault's own gauge interaction code remain in scope.

### One-Time GaugeManager Binding (Accepted Operational Risk)

`V3Vault.setGaugeManager` is intentionally one-shot and irreversible.

- The setter only validates that the provided address is a contract and then permanently locks the manager address.
- Misbinding to an incompatible manager (for example, a manager deployed for a different vault) can break stake/unstake/compound paths and cannot be corrected on-chain.
- This is treated as deployment/governance operational risk (owner misconfiguration), not a permissionless exploit.

Reviewer guidance:

- Findings that require owner misconfiguration of this one-time parameter should be classified as configuration/governance risk unless a recoverable binding mechanism is explicitly introduced.
- Findings about logic bugs that occur with a correctly configured manager remain fully in scope.

## 7) Liquidation Identity Policy (Accepted Behavior)

The protocol does not restrict who can call `liquidate` — including the position owner liquidating their own loan. Self-liquidation does not create an incentive loop because the penalty is extracted from the borrower's own collateral. The liquidator and borrower are the same economic actor, so no value is created.

This is consistent with standard lending protocol behavior (Aave, Compound do not block self-liquidation).

Reviewer guidance:
- Findings about the absence of a `msg.sender != tokenOwner[tokenId]` check, or that self-liquidation is possible, should be classified as accepted design behavior.
- Findings about bugs in liquidation math, penalty calculation, or reserve handling that apply regardless of caller identity remain in scope.

## 8) Governance Parameter Changes (Accepted Operational Behavior)

Governance-controlled parameters such as collateral factors (`setTokenConfig`) take effect immediately when set. If collateral factors are reduced, positions near the liquidation boundary may become immediately liquidatable in the same block.

This is standard behavior for admin-controlled lending parameters:
- Governance is expected to use timelocks, multisigs, and gradual parameter changes in production.
- The protocol does not implement on-chain ramp/delay mechanisms for parameter changes — this is delegated to the governance layer.
- Aave, Compound, and other lending protocols have the same property.

Reviewer guidance:
- Findings about the absence of on-chain timelock or ramping for collateral factor changes should be classified as accepted governance operational behavior.
- Findings about bugs in how parameter changes propagate to health checks, or unexpected interactions between simultaneous parameter changes, remain in scope.

## 9) Swap Infrastructure Trust Model (Accepted Deployment Trust)

The `Swapper` contract relies on deployment-configured trusted addresses for swap execution:
- `zeroxAllowanceHolder` — the 0x AllowanceHolder contract
- `universalRouter` — the Uniswap Universal Router

These are immutable deployment-time trust decisions, analogous to the oracle address or gauge address. The protocol trusts these addresses to execute swaps correctly.

Reviewer guidance:
- Findings premised on the `zeroxAllowanceHolder` or router being compromised or misconfigured should be classified as deployment trust assumptions, not protocol vulnerabilities. The vault owner is responsible for configuring correct, vetted addresses.
- Findings about bugs in how the Swapper interacts with correctly configured swap infrastructure (e.g., insufficient output validation, leftover token handling) remain in scope.

## 10) Audit Scope Exclusions

The following are explicitly out of scope for this audit:
- **Foundry toolchain bugs**: Issues with `forge test` runtime panics, host-level crashes, or CI environment problems are not protocol findings. They affect test coverage confidence but not deployed contract security.

## 11) Transformer Trust Model

The transformer set is closed and fully audited:

- Only the contracts in `src/transformers/` (V3Utils, AutoRangeAndCompound, LeverageTransformer) will ever be whitelisted.
- Each transformer is included in the audit scope and individually reviewed as part of this codebase.
- No third-party or future transformers will be added without a dedicated audit.
- Transformers have high trust during transform mode: they can call `borrow()` on the vault for the currently transformed token, and health checks are deferred until the transform completes atomically.
- This is by design. Findings premised on "an attacker whitelists a malicious transformer" are out of scope.
  Findings about bugs, unexpected interactions, or design flaws WITHIN the audited
  transformers (V3Utils, AutoRangeAndCompound, LeverageTransformer) remain fully in scope.

Recommended high-signal test files:

- `test/atlas/AtlasTransitions.t.sol`
- `test/integration/aerodrome/GaugeManagerVulnerability.t.sol`
