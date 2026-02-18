# Vault‑First + Strict Manual Automation Spec (Single File)
**Implementation target:** codebase in `lend-fix-gauge-manager-vulnerability` (Foundry).  
**Design choice:** Full simplification + strict manual automation using **Option S2** (`V3Vault.unstakeTransformStake`).  
**Key outcome:** Minimal, safest possible reachable custody/migration paths while preserving *all* user functionality (stake, claim/compound rewards, auto-range, zaps, tokenId migration, leverage transforms), even if it requires more transactions.

---

## 0) Goals & Non‑Goals

### Goals
1) **Minimize reachable custody/migration paths**:
   - Make the vault the single canonical “account system” for all positions.
   - Any `tokenId` migration happens **only** in `V3Vault` transform-mode callback logic.
2) **Strict manual automation**:
   - `V3Vault.transform(...)` becomes **unstaked-only**.
   - A new explicit entrypoint `V3Vault.unstakeTransformStake(...)` becomes the only supported path to “do work while staked”.
3) **Remove direct staking mode** (wallet → GaugeManager custody):
   - Users who want automation/zaps but no loans must still deposit positions into the vault with **debt=0**.
4) **Reduce GaugeManager to a vault-controlled staking/rewards adapter**:
   - Remove GM tokenId migration / transformer execution / V3Utils execution surfaces.
   - Hard reject stray NFT transfers into GM (no stranding).
5) Preserve all functionality:
   - Users can still stake, unstake, compound, auto-range, auto-compound, and execute transforms that change `tokenId`.
   - More tx is acceptable and expected.

### Non‑Goals
- Handling migration of already deployed direct-mode positions is out-of-scope unless explicitly required (see §10).
- Economic parameter tuning (slippage bounds, fee bps, oracle config) is out of scope except where it blocks debt=0 users.

---

## 1) New Minimal Path Atlas (v2)

### Actors
- **W** = user wallet / EOA
- **V** = `V3Vault` (canonical custody + owner registry)
- **GM** = `GaugeManager` (vault-only staking + rewards)
- **G** = Aerodrome gauge
- **T** = transformer (AutoRange / AutoCompound / V3Utils / LeverageTransformer / etc.)
- **NPM** = nonfungible position manager (ERC721)

### Allowed custody paths (ONLY)
1) **Deposit:** `W -> V` (only via `V.create` / `V.createWithPermit`)
2) **Withdraw:** `V -> W` (only via `V.remove`; auto-unstake OK)
3) **Stake:** `V -> GM -> G` (only via `V.stakePosition`; GM callable only by V)
4) **Unstake:** `G -> GM -> V` (only via `V.unstakePosition`; GM callable only by V)
5) **Transform (unstaked):** `V -> T -> V` (tokenId may change; only V migrates)
6) **Transform (staked wrapper):** `V.unstakeTransformStake`: `G -> GM -> V -> T -> V -> GM -> G`
7) **Compound rewards (staked):** `V.compoundRewards -> GM.compoundRewards -> (withdraw/claim/increase/deposit)`  
   **Constraint:** tokenId MUST NOT change in compound path.

### Explicitly removed / forbidden paths
- `W -> GM -> G` direct stake/unstake (direct mode)  
- `GM.transform`, `GM.executeV3UtilsWithOptionalCompound`, `GM.migrateToVault`  
- Any transformer path via GM (`executeWithGauge`, `executeForGauge`)  
- Raw custody callbacks that accept unmanaged NFTs:
  - `W -> GM` by `safeTransferFrom`
  - `W -> V` by `safeTransferFrom` (new deposits must be via `create*`)

---

## 2) High‑Level Invariants (Must Hold)

### I0 — Vault is canonical owner registry
`V3Vault.tokenOwner[tokenId]` is the canonical owner for all supported positions, including debt=0.

### I1 — Only V3Vault may migrate tokenId
If a transform mints a new NFT, only the vault updates:
- loan/position accounting
- ownership mapping
- staked state handoff (via restake from wrapper)

### I2 — Strict unstaked-only transform
`V3Vault.transform(...)` MUST revert if the token is currently staked.

### I3 — Single explicit staked automation entrypoint
`V3Vault.unstakeTransformStake(...)` is the ONLY supported entrypoint that:
- unstake (if needed)
- transform (unstaked)
- stake back (if it was staked)

### I4 — GM is vault-only for NFT-touching functions
`GaugeManager.stakePosition`, `unstakePosition`, `compoundRewards` are callable **only by the vault**.

### I5 — No stray NFT acceptance
`GaugeManager.onERC721Received` and `V3Vault.onERC721Received` MUST reject unmanaged “random safeTransferFrom” deposits.

### I6 — Debt=0 users must not be blocked by oracle checks
After transforms, health/oracle checks MUST be conditional:
- If `debtShares == 0`: skip oracle health check.
- If `debtShares > 0`: enforce existing health/oracle checks.

---

## 3) Required Contract API Changes

### 3.1 `src/interfaces/IVault.sol`
Add:
```solidity
function unstakeTransformStake(
    uint256 tokenId,
    address transformer,
    bytes calldata data
) external returns (uint256 newTokenId);

4) V3Vault.sol Changes (Core)

4.1 Make transform(...) unstaked-only

Requirement: V3Vault.transform MUST revert if the token is staked.

Implementation:
	•	Add a staked check at the top of transform(...):
	•	If gaugeManager != address(0) and IGaugeManager(gaugeManager).tokenIdToGauge(tokenId) != address(0), revert.

Add a new custom error (recommended):
error PositionIsStaked();

4.2 Add new entrypoint unstakeTransformStake(...) (Option S2)

Add the function with signature in IVault.

Behavior:
	1.	Perform the same auth checks as transform(...):
	•	transformer allowlist
	•	caller = owner OR approved transform delegate (whatever the current vault rules are)
	•	reentrancy guard state (transformedTokenId == 0)
	2.	Determine wasStaked using IGaugeManager.tokenIdToGauge(tokenId).
	3.	If wasStaked: call IGaugeManager.unstakePosition(tokenId).
	4.	Execute the transform using a shared internal function:
	•	Refactor the core logic of transform(...) into _transformUnstaked(...).
	•	transform(...) becomes:
	•	check !staked
	•	call _transformUnstaked(...)
	•	unstakeTransformStake(...):
	•	optional unstake
	•	call _transformUnstaked(...)
	•	optional restake
	5.	If wasStaked: stake the resulting newTokenId:
	•	NPM.approve(gaugeManager, newTokenId)
	•	IGaugeManager.stakePosition(newTokenId)
	6.	Return newTokenId.

Important: _transformUnstaked(...) is allowed to change tokenId and must continue to rely on the vault’s transform-mode callback to migrate.

4.3 Health check must be conditional on debtShares > 0

Inside _transformUnstaked(...) (or at the end of transform logic), enforce:
	•	If loans[newTokenId].debtShares == 0: skip _requireLoanIsHealthy(...) / oracle calls.
	•	Else: keep existing behavior.

Rationale: in this design, debt=0 positions are still deposited into the vault to use automation and should not require oracle value support.

4.4 Harden deposits: forbid raw “P18” deposits into vault

Currently, vault onERC721Received can create ownership for a brand new token if tokenOwner[tokenId] == 0.

Requirement: Only allow new deposits if initiated by create/createWithPermit (explicit managed flow).

Implement “pending deposit” gating:

Add:

mapping(uint256 => address) public pendingDepositRecipient;


In create / createWithPermit:
	•	Set pendingDepositRecipient[tokenId] = recipient;
	•	Then call safeTransferFrom(W -> V, tokenId, abi.encode(recipient))

In onERC721Received, for the branch where tokenOwner[tokenId] == 0 (new position):
	•	Require pendingDepositRecipient[tokenId] != address(0) else revert (new error UnexpectedDeposit() recommended)
	•	Set owner = pendingDepositRecipient[tokenId]
	•	Delete pendingDepositRecipient[tokenId]

Do NOT apply this restriction to:
	•	returning staked NFTs (existing token branch)
	•	transform-mode minted NFT returns (transform sentinel branch)

4.5 Remove implicit auto-unstake/restake inside transform

After adding unstaked-only check, delete/disable any internal logic that:
	•	detects staked and calls _unstakeIfNeeded inside transform
	•	restakes at the end of transform

All staked automation goes through unstakeTransformStake.

5) GaugeManager.sol Changes (Make GM Vault‑Only & Minimal)

5.1 Add onlyVault modifier and apply broadly

Add:

modifier onlyVault() {
    if (msg.sender != address(vault)) revert Unauthorized();
    _;
}

Apply onlyVault to:
	•	stakePosition(uint256 tokenId)
	•	unstakePosition(uint256 tokenId)
	•	compoundRewards(...)
	•	(optional) any “claim rewards” function if kept

5.2 Remove all GM transform/tokenId migration surfaces

Delete the following features and associated storage/events:
	•	transform(...) and transformer allowlists
	•	executeV3UtilsWithOptionalCompound(...) and v3Utils config
	•	migrateToVault(...)
	•	direct-mode owner tracking: positionOwners, isVaultPosition
	•	transform approvals (transformApprovals)
	•	reentrancy sentinel transformedTokenId in GM

After simplification:
	•	GM must never remap tokenId.
	•	GM must never call transformers.
	•	GM must never call V3Utils.

5.3 Owner resolution

GM should no longer store position owners.
When it needs to send rewards to the user, resolve:

address owner = vault.ownerOf(tokenId);
5.4 Reject stray NFT transfers into GM (eliminate stranding)

Implement strict “expected transfer” gating.

Add storage:

address private expectedNftFrom;
uint256 private expectedNftTokenId;
bool private expectingNft;


Set expectations in flows:
	•	In stakePosition(tokenId):
	•	expectingNft = true; expectedNftFrom = address(vault); expectedNftTokenId = tokenId;
	•	NPM.safeTransferFrom(vault, address(this), tokenId);
	•	then proceed to gauge.deposit(tokenId)
	•	In unstakePosition(tokenId):
	•	before gauge.withdraw(tokenId) set:
	•	expectingNft = true; expectedNftFrom = gauge; expectedNftTokenId = tokenId;
	•	After withdrawal, GM will receive tokenId; then GM transfers to vault.
	•	In compoundRewards(...):
	•	similar: expect NFT from gauge when withdrawing tokenId

In onERC721Received:
	•	Require msg.sender == address(NPM)
	•	Require expectingNft == true
	•	Require from == expectedNftFrom and tokenId == expectedNftTokenId
	•	Clear expectation state (expectingNft=false; expectedNftFrom=0; expectedNftTokenId=0)
	•	Return selector

If any check fails: revert UnexpectedNFT().

This guarantees GM can never custody an NFT unless it is in a managed stake/unstake/compound flow.

5.5 Reward handling simplification (recommended)

The existing GM has complexity around accumulated AERO for vault positions.

Recommended simplified behavior:
	•	On unstakePosition: claim AERO and send it directly to vault.ownerOf(tokenId) (or keep it in GM only as fees, if fees exist).
	•	On compoundRewards: claim AERO, take fee cut, and reinvest the remainder; no persistent per-owner accounting needed.

If a separate “claim rewards” is required:
	•	Keep claimRewards(tokenId) vault-only and send to vault.ownerOf(tokenId).


6) Transformers: Route Everything Through Vault (No GM Entry Points)

6.1 AutoRange.sol

Requirements:
	•	Remove gauge-manager entrypoints (and allowlists) entirely:
	•	Delete executeWithGauge(...)
	•	Delete gaugeManagers allowlist
	•	Remove any conditional auth based on being called by a gauge manager
	•	Update vault automation entrypoints to use S2:
	•	executeWithVault(...) and autoCompoundWithVault(...) must call:
	•	IVault(vault).unstakeTransformStake(tokenId, address(this), encodedCallData)
	•	NOT IVault(vault).transform(...)

6.2 AutoCompound.sol

Same requirements as AutoRange:
	•	Delete executeWithGauge(...), executeForGauge(...), gauge-manager allowlist
	•	Update executeWithVault(...) to call unstakeTransformStake(...) rather than transform(...)

6.3 (Optional but recommended) V3Utils.sol

If “full simplification” means minimizing public custody surfaces:
	•	Disable ERC721 callback-based usage (W -> V3Utils by safeTransferFrom).
	•	Either remove onERC721Received or make it always revert.
	•	Keep execute(...) only via approvals or via vault transform path.

This eliminates an entire extra custody path that is no longer needed.

⸻

7) Vault ↔ GM Coupling Rules

7.1 GM calls only originate from the vault

Because GM is vault-only:
	•	No external user calls to GM should succeed.
	•	Any UI / operator must call the vault, not GM.

7.2 Staked transforms MUST be done via unstakeTransformStake
	•	V.transform reverts when staked.
	•	Bots/operators should call unstakeTransformStake via transformer wrapper entrypoints (AutoRange/AutoCompound) or directly (advanced integrators).

7.3 Compound remains staked-only and tokenId-stable
	•	V.compoundRewards should continue to function.
	•	GM.compoundRewards must never change tokenId.

⸻

8) Required New Errors / Events (Suggested)

Errors
	•	error PositionIsStaked(); (Vault)
	•	error UnexpectedDeposit(); (Vault)
	•	error UnexpectedNFT(); (GM)

(You can reuse existing Unauthorized() if it already exists; otherwise add one.)

Events

No new events strictly required, but it can be useful to emit:
	•	event UnstakeTransformStake(uint256 oldTokenId, uint256 newTokenId, address transformer, address caller);

⸻

9) Acceptance Criteria (“Definition of Done”)

A) Minimal paths enforced
	•	Direct stake/unstake to GM from wallet is impossible (reverts).
	•	GM has no transform/V3Utils execution entrypoints.
	•	GM rejects stray NFT transfers; cannot strand NFTs.

B) Transform strictness
	•	If staked:
	•	V.transform MUST revert with PositionIsStaked.
	•	V.unstakeTransformStake MUST succeed and end staked (if it started staked).
	•	If unstaked:
	•	V.transform works.
	•	V.unstakeTransformStake works and ends unstaked (if it started unstaked).

C) TokenId migration correctness
	•	If transform changes tokenId:
	•	vault migrates owner/loan bookkeeping from old to new
	•	old tokenId no longer considered active
	•	if wrapper restaked: new tokenId is the one staked in gauge/GM mapping

D) Deposit hardening
	•	Raw NPM.safeTransferFrom(user -> vault) for a new tokenId MUST revert.
	•	V.create / V.createWithPermit deposits succeed.

E) Debt=0 support
	•	debt=0 users can deposit into vault, stake, and run transforms/automation without oracle/health check blocking.

⸻

10) Migration Notes (Optional / Out‑of‑Scope)

If there are already live positions staked directly in the current GM (wallet → GM legacy), those positions will not be manageable under the new GM once direct mode is removed.

Possible approaches (not required by this spec):
	1.	Leave old GM deployed for legacy exits, and deploy new GM/vault for new flows.
	2.	Implement a one-time migrator that can withdraw legacy positions and deposit into the vault.

⸻

11) Test Plan (Foundry) — Must Add/Update

Add or extend tests to cover:
	1.	Deposit gating
	•	raw safeTransferFrom(user -> vault) for new tokenId reverts (UnexpectedDeposit)
	•	create/createWithPermit works
	2.	GM stray transfer gating
	•	raw safeTransferFrom(user -> GM) reverts (UnexpectedNFT)
	3.	Transform strictness
	•	stake token via vault
	•	calling V.transform reverts with PositionIsStaked
	•	calling V.unstakeTransformStake succeeds and ends staked
	4.	Debt=0 transform
	•	deposit into vault without borrow (debtShares = 0)
	•	call unstakeTransformStake via AutoRange/AutoCompound; succeeds without oracle requirement
	5.	TokenId migration + wrapper restake
	•	use a transformer path that mints a new token (change-range)
	•	ensure vault migrates and wrapper restakes new tokenId
	•	ensure GM mapping points to new tokenId gauge; old mapping removed

⸻

12) Implementation Checklist (Quick)
	•	Add unstakeTransformStake to IVault and implement in V3Vault
	•	Refactor vault transform logic into _transformUnstaked shared by both entrypoints
	•	Make V.transform revert if staked
	•	Skip health/oracle checks when debtShares == 0
	•	Add pending-deposit gating to block raw deposits into vault
	•	Simplify GM: vault-only + remove transforms/V3Utils/migration + remove direct-mode tracking
	•	Add strict onERC721Received gating in GM with expected transfer flags
	•	Remove gauge-manager entrypoints from AutoRange/AutoCompound
	•	Update AutoRange/AutoCompound vault entrypoints to call unstakeTransformStake
	•	(Optional) disable V3Utils ERC721 callback custody path
	•	Update/extend tests
	•	Update docs/integration notes