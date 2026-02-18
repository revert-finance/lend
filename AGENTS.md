# Agent Docs Index (Phoenix)

Use these docs first when working in this repository:

1. `docs/agents/protocol-primer.md`
2. `docs/agents/risk-and-acceptability.md`
3. `docs/agents/aerodrome-staking-and-gauge-manager.md`
4. `NFT_PATH_ATLAS.md` (custody path and transition atlas)

## Source-of-Truth Rule

- If docs and code disagree, treat Solidity code as source of truth.
- Primary contracts: `src/V3Vault.sol`, `src/V3Oracle.sol`, `src/InterestRateModel.sol`, `src/GaugeManager.sol`.
- High-signal behavior tests: `test/atlas/AtlasTransitions.t.sol`, `test/audit/AuditProperties.t.sol`, `test/integration/aerodrome/GaugeManagerVulnerability.t.sol`.

## Scope Note

- The docs above summarize the Revert Lend whitepaper and this Aerodrome fork's implemented behavior.
- Some older notes in `INTEGRATION_GUIDE.md` may be stale relative to current ABI; verify against `src/interfaces/`.
