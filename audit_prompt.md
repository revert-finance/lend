
# Multi-Agent Smart Contract Audit — Long-Horizon Codex Harness (One-File Prompt)

> **Operating mode:** This is a *defensive* security review for fund safety. All exploit traces/PoCs must be for **local testing only** (Foundry/Hardhat/etc). 

## Core objective
You have **zero prior context**. Do not assume intent. Derive behavior from code only. Optimize for **fund safety** and **exploit discovery**.

Protocol: DeFi system involving **NFT-based LP positions (Aerodrome/UniswapV3-style), Vaults, Gauge staking, Lending/Debt, Liquidations, and Reward compounding**. A previous version was exploited (details unknown). Your job is to rediscover any plausible exploit class and prove safety via explicit invariants and traces.

---

# Codex Execution Contract (makes this go deep)

## Artifact-first (required)
Create and maintain these files (write them; don’t just describe them):
- `audit/00_SCOPE.md` — assumptions, threat model, trusted vs untrusted dependencies
- `audit/01_SYSTEM_MAP.md` — modules/contracts + trust boundaries
- `audit/02_NFT_ATLAS.md` — NFT custody state machine + transitions
- `audit/03_ERC20_DEBT_ATLAS.md` — all asset/debt flows + storage vars touched
- `audit/04_INVARIANTS.md` — 20+ invariants, each mapped to enforcement or **Missing**
- `audit/05_FINDINGS.md` — ranked findings + hypotheses + status (OPEN/REFUTED/CONFIRMED), **minimum 40 entries**
- `audit/06_EXPLOIT_TRACES.md` — **40 narratives** with tx-by-tx traces + why checks fail/hold
- `audit/07_EXTERNAL_CALLS_REENTRANCY.md` — every external call site, risk, mitigation
- `audit/08_TEST_PLAN.md` — property + scenario + fuzz plan
- `audit/REPORT.md` — the combined final report in the required format

**Chat output discipline:** Keep the interactive response short. The full report must live in `audit/REPORT.md`.

## Verification gates (required)
You are **not done** until all gates are satisfied:

GATE A — Toolchain discovery + baseline build:
- Detect toolchain (Foundry/Hardhat/Truffle/etc).
- Run the project’s standard build/compile command.
- Run the project’s standard test command (even if it fails; record failures).

GATE B — Static & structural analysis:
- Enumerate all contracts, all public/external entrypoints, and all external dependencies.
- Produce an “external call site” inventory (ERC20/721 transfers, router/gauge/oracle calls, delegatecalls).

GATE C — Adversarial validation:
- Attempt **40 exploit narratives** (NFT misdirection, accounting/donation/rounding, liquidation/oracle).
- Each narrative must include an explicit tx sequence and identify the exact defense (or missing defense).

GATE D — Tests that would catch the exploit:
- Add/outline Foundry-style tests. Implement at least:
  - 40 property/invariant tests
  - 40 scenario tests
  - 1 reentrancy harness (ERC721Receiver + ERC20 callback simulation)
- Run tests again after adding them (or explain why cannot run).

GATE E — Cardinality enforcement (hard requirement):
- `audit/05_FINDINGS.md` must contain **at least 40 uniquely named findings** (`F-01`..`F-40+`).
- `audit/06_EXPLOIT_TRACES.md` must contain **at least 40 exploit narratives** (`N-01`..`N-40+`).
- `audit/08_TEST_PLAN.md` must contain **at least 40 property tests and 40 scenario tests**.
- If any cardinality target is missed, the run is **incomplete** and must continue.

## Mandatory depth: two-pass audit
You must do **two full passes**:

### PASS 1 — Discovery
Run Agents A→G in order, writing artifacts.

### PASS 2 — Refutation + Hardening
Run Agents A→G again, but this time your job is to:
- **disprove** PASS 1 claims,
- close hypotheses (REFUTED/CONFIRMED),
- turn top risks into tests,
- re-run tests and update findings.

Stop only after PASS 2 artifacts are updated and `audit/REPORT.md` is rebuilt.

---

# Global Rules (apply to every agent)

## Evidence standard
- No hand-waving. Every claim must cite **exact functions** and **state variables** involved (file/function names are sufficient if line numbers aren’t available).
- For each finding, include:
  1) impacted asset (NFT / ERC20 / accounting / permissions)
  2) preconditions
  3) attack steps (transaction sequence)
  4) why checks fail
  5) code references (file + function + key lines/logic)
  6) severity + likelihood
  7) minimal fix
  8) regression test idea (Foundry-style)

## Output discipline
- If you can’t prove it, label it **Hypothesis** and provide a concrete test to validate/refute it.
- Always output:
  - at least 40 ranked findings/hypotheses (including near-miss hazards if exploitability is low),
  - hardest-to-test assumptions,
  - the tests that would convince you.

## Adversary model (default)
Assume an adversary can:
- front-run / back-run,
- use flash loans,
- call any public/external function,
- deploy malicious ERC20 (non-standard returns, fee-on-transfer, rebasing),
- deploy malicious receiver contracts (ERC721Receiver reentrancy),
- interact with external gauges/routers if those are not strongly trusted.

---

# Roles / Agents
Run these agents **in order**. Later agents may not assume earlier agents are correct; they should verify.

1) **Agent A — Cartographer (System + Asset Atlas)**
2) **Agent B — Invariant Engineer (Explicit invariants + where enforced)**
3) **Agent C — Exploit Constructor (40 exploit narratives + attempted traces)**
4) **Agent D — Liquidation & Oracle Specialist**
5) **Agent E — External Calls & Reentrancy Skeptic**
6) **Agent F — Test Architect (property tests + fuzz plan + 40x40 regression suite)**
7) **Agent G — Final Judge (risk ranking + ship/no-ship + required fixes)**

---

# Agent A — Cartographer (Mandatory First)
## A0) Repository intake (Codex-specific)
- Enumerate repo structure and Solidity entrypoints.
- Identify build/test toolchain.
- Identify any deployed addresses/constants, config files, and external dependency wiring.

Record results in:
- `audit/00_SCOPE.md`
- `audit/01_SYSTEM_MAP.md`

## A1) System Map
- Enumerate all contracts/modules and responsibilities.
- Identify all external dependencies (Aerodrome, NPM, gauges, routers, oracles, ERC20s).
- Draw trust boundaries: which external addresses are assumed honest vs adversarial.

## A2) NFT Atlas (state machine)
Build a full state machine of where an LP NFT can be, including at minimum:
- User wallet
- Vault custody (unstaked)
- Gauge custody (staked)
- “in transfer” transient states
- liquidation custody/receiver
- withdraw/unstake flows
- compound/harvest flows

For each transition:
- initiator, caller/callee, required approvals, expected `msg.sender`
- any onERC721Received logic + conditions (e.g., “expected NFT transfer” patterns)
- failure modes: can it revert mid-way and strand state? can it lock permanently?
- can NFT be redirected to attacker-controlled recipient?

Write to `audit/02_NFT_ATLAS.md`.

## A3) ERC20 / USDC / Debt Atlas
Map all flows:
- deposit/mint shares
- borrow/repay
- withdraw/redeem
- liquidation seize/repay
- harvest/compound/reward accounting
For each flow:
- which storage variables update
- what enforces conservation and prevents silent leakage

Write to `audit/03_ERC20_DEBT_ATLAS.md`.

**Deliverable:** concise but complete maps + list of all “asset-holding” contracts.

---

# Agent B — Invariant Engineer
Write **20+ explicit invariants** grouped:

## B1) Ownership / Authorization
Examples (adapt to actual code):
- Only position owner (or approved operator) can initiate withdrawals / unstake.
- Only authorized managers can interact with gauges on behalf of users.
- No NFT transfer is accepted unless it matches an explicit expected-transfer allowance.

## B2) Accounting
- `totalAssets` matches actual underlying + staked + claimable (as defined)
- share mint/burn matches asset deltas
- debt variables cannot be desynced by reentrancy or donation
- interest accrual is monotonic and applied consistently

## B3) Conservation
- no ERC20 can leave without corresponding accounting update
- fees are bounded and cannot exceed defined maxima
- rewards claimed are either distributed or recorded; never lost silently

## B4) Liquidation safety
- seize >= repay * price * (1+bonus) (as defined)
- cannot self-liquidate for profit if prohibited
- partial liquidation cannot under-repay or over-seize due to rounding

## B5) Liveness
- solvent users can always exit
- paused/emergency still permits safe exit paths (if intended)

For each invariant:
- show exactly where it’s enforced (functions/conditions) or label **Missing**.

Write to `audit/04_INVARIANTS.md`.

---

# Agent C — Exploit Constructor (Rediscover the old exploit)
Without knowing prior exploit details, generate **40 plausible exploit narratives** and try to validate them against code:

## C1) NFT misdirection or permanent lock
- attack via ERC721 receiver assumptions, “expected transfer” logic, or msg.sender/from confusion
- multi-step sequences: stake → withdraw → reenter → redirect → finalize

## C2) Accounting inflation / donation / rounding-to-zero
- manipulate share minting, debt shares, reward shares
- exploit donation of underlying before mint, or rounding on small deposits/borrows
- check “maxAdd rounds to 0” style edge cases

## C3) Liquidation/oracle manipulation
- stale oracle, TWAP window, decimals mismatch
- flashloan to swing price source if manipulable
- liquidation math rounding leading to bad debt or free collateral

For each narrative:
- give the exact call sequence (tx-by-tx)
- identify the line of defense; if absent, it’s a finding
- if present, explain why it is robust or fragile
- if uncertain, mark **Hypothesis** and propose a concrete Foundry test/PoC

Write to:
- `audit/06_EXPLOIT_TRACES.md`
- update `audit/05_FINDINGS.md`

---

# Agent D — Liquidation & Oracle Specialist
Deep dive only on liquidation + oracle paths:
- enumerate all oracle reads (where, how, decimals, staleness checks)
- identify all liquidation entrypoints and state updates order
- check: self-liquidation rules, partial liquidation, debt accounting, collateral valuation, liquidation incentive bounds
- look for grief/DoS (e.g., revert loops, unbounded loops, price = 0 handling)

Deliverable:
- liquidation-specific findings + oracle risk rating in `audit/05_FINDINGS.md`
- detailed notes in `audit/REPORT.md` section 5 and/or a dedicated subsection

---

# Agent E — External Calls & Reentrancy Skeptic
Systematically audit:
- every external call site (ERC20 transfer, gauge, router, NPM, oracle)
- ordering of checks-effects-interactions
- reentrancy guards and whether they cover all critical paths
- ERC721Receiver callback reentrancy
- ERC20 non-standard behavior handling (return values, fee-on-transfer, rebasing)

For each risky call:
- explain worst-case adversarial behavior
- show what prevents it (guard, state ordering, pull pattern, etc.)
- if nothing prevents it, propose minimal fix

Write to `audit/07_EXTERNAL_CALLS_REENTRANCY.md` and update `audit/05_FINDINGS.md`.

---

# Agent F — Test Architect (Foundry)
Produce a test plan that would catch the real exploit and prevent regressions:

## F1) Property tests (invariants as fuzz properties)
At least 40, e.g.:
- conservation of NFT custody mapping vs actual ownerOf
- shares monotonicity under deposits/withdrawals
- debt cannot decrease without repayment
- liquidation cannot create profit loops

## F2) Scenario tests (directed)
At least 40, including:
- stake/unstake/withdraw permutations
- reentrancy attacker contract (ERC721Receiver + ERC20 callback simulation)
- donation attacks before mint
- rounding edge cases (tiny amounts, maxAdd rounding, dust debt)
- oracle stale/zero/extreme values

For each test:
- name
- setup
- sequence
- assertions

## F3) Fuzz targets
List the top contracts/functions to fuzz with reasons.

Write to `audit/08_TEST_PLAN.md`.
If Foundry exists, implement the required 40x40 regression suite under `test/` and run it.

---

# Agent G — Final Judge (Ship/no-ship)
Based on all prior outputs (and your own verification):
- Rank top risks (Critical/High/Med/Low)
- Identify “must-fix before deploy” items
- Identify “acceptable with monitoring” items
- Provide a **ship/no-ship** recommendation and the minimal patch set required for ship.

Update `audit/REPORT.md` and ensure it matches the Required Final Output Format below.

---

# Required Final Output Format (single combined report in audit/REPORT.md)
1) System Overview
2) NFT Atlas
3) ERC20/USDC/Debt Atlas
4) Invariants (20+)
5) Findings (ranked, **minimum 40**)
6) Top 40 Risk Hotspots / Near-Miss Hazards (even if no vulns found)
7) Test Plan (property + scenario + fuzz)
8) Final Decision (ship/no-ship + required fixes)

---

# Start Here
Begin now with **PASS 1**, **Agent A**:
1) enumerate all contracts and dependencies
2) build the NFT Atlas first
3) then the ERC20/USDC/Debt Atlas
Then proceed through Agents B→G.
After PASS 1 completes, immediately start PASS 2 (A→G again) for refutation + hardening.
