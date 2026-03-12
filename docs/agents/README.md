# Agent-Facing Protocol Docs

This folder is for fast protocol orientation and safe implementation guidance.

- `protocol-primer.md`: high-level model from the Revert Lend whitepaper, mapped to this codebase.
- `risk-and-acceptability.md`: protocol risk model — health checks, liquidation behavior, oracle failure policy, rate accrual, limits, transformer trust boundaries, and hard assumptions (including lending asset compatibility).
- `aerodrome-staking-and-gauge-manager.md`: Aerodrome-specific staking and gauge integration that does not exist in the base whitepaper.

## Document Hierarchy

1. Solidity contracts and interfaces in `src/`
2. Behavior tests in `test/`
3. These docs
4. Legacy guides if they conflict with the above

## Primary Whitepaper Source

- `https://github.com/revert-finance/lend-whitepaper/blob/main/Revert_Lend-wp.pdf`
