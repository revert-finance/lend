// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./GaugeManager.sol";
import "./interfaces/aero/IAeroGauge.sol";

/// @notice Vault-only Aero staking adapter. Deferred rewards belong to the economic owner at withdrawal.
/// @dev A batch comprises one gauge's deferrals since its previous successful recovery. Recovery funds
/// all claims in that batch without iterating owners. Claims survive NFT removal, transfer and liquidation.
/// Only direct LeafEmissionsHandler delivery is supported: `aeroToken` is the local RECEIPT_TOKEN,
/// NOT the legacy or root AERO token. RootEmissionsHandler's pendingRedeems need a separate adapter.
/// Configured gauges and the immutable vault/token/NPM are trusted protocol dependencies.
contract AeroGaugeManager is GaugeManager {
    using SafeERC20 for IERC20;

    error DeferredAccountingMismatch();
    error UnknownGauge();
    error OnlySelf();
    error NoDeferredClaim();
    error UnsupportedRewardDelivery();

    struct DeferredBatch {
        uint256 amount;
        bool recovered;
    }

    mapping(address => bool) public knownGauges;
    mapping(address => uint256) public currentDeferredBatch;
    mapping(address => mapping(uint256 => DeferredBatch)) public deferredBatches;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public deferredClaims;

    /// @notice Receipt tokens already recovered but owed to users; excluded from admin withdrawals and new claims.
    uint256 public reservedRewards;

    event DeferredRewardRecorded(
        address indexed gauge, uint256 indexed batch, address indexed owner, uint256 tokenId, uint256 amount
    );
    event DeferredRewardsRecovered(address indexed gauge, uint256 indexed batch, uint256 amount);
    event DeferredRewardsClaimed(
        address indexed gauge, uint256 indexed batch, address indexed owner, address recipient, uint256 amount
    );

    constructor(INonfungiblePositionManager npm, IERC20 token, IVault vault_, address router, address allowanceHolder)
        GaugeManager(npm, token, vault_, router, allowanceHolder)
    {}

    function setGauge(address pool, address gauge) public override onlyOwner {
        super.setGauge(pool, gauge);
        if (IAeroGauge(gauge).nft() != address(nonfungiblePositionManager) || IAeroGauge(gauge).pool() != pool) {
            revert InvalidPool();
        }
        address voter = IAeroGauge(gauge).voter();
        IAeroLeafVoter leafVoter = IAeroLeafVoter(voter);
        IAeroLeafEmissionsHandler handler = IAeroLeafEmissionsHandler(leafVoter.EMISSIONS_HANDLER());
        // RootEmissionsHandler deliberately has no RECEIPT_TOKEN getter, so it cannot pass this check.
        if (
            leafVoter.RECEIPT_TOKEN() != address(aeroToken) || handler.RECEIPT_TOKEN() != address(aeroToken)
                || handler.LEAF_VOTER() != voter
        ) revert UnsupportedRewardDelivery();
        // Keep previous gauges registered: their deferred claims survive a pool's gauge replacement.
        knownGauges[gauge] = true;
    }

    /// @notice Recover a whole batch into escrow; this never pays the caller or needs a live NFT.
    function recoverDeferredRewards(address gauge) external nonReentrant returns (uint256 amount) {
        return _recoverDeferredRewards(gauge);
    }

    /// @notice Redeem the caller's entitlement from a specific batch, even after leaving the vault.
    /// @dev Recover an unfunded current batch first. Failure here cannot block a separate principal exit.
    function claimDeferredRewards(address gauge, uint256 batch, address recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (recipient == address(0)) revert InvalidConfig();
        amount = deferredClaims[gauge][batch][msg.sender];
        if (amount == 0) revert NoDeferredClaim();
        if (!deferredBatches[gauge][batch].recovered) {
            _recoverDeferredRewards(gauge);
            if (!deferredBatches[gauge][batch].recovered) revert DeferredAccountingMismatch();
        }
        delete deferredClaims[gauge][batch][msg.sender];
        reservedRewards -= amount;
        aeroToken.safeTransfer(recipient, amount);
        emit DeferredRewardsClaimed(gauge, batch, msg.sender, recipient, amount);
    }

    /// @notice Position earnings only. Aero's raw singleton earned() also includes account-wide deferrals.
    function positionRewards(uint256 tokenId) external view returns (uint256) {
        address gauge = _requireStakedGauge(tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        return IAeroGauge(gauge).earned(address(this), ids) - IAeroGauge(gauge).deferredEmissions(address(this));
    }

    /// @dev External self-call makes recovery + position claim atomic inside the best-effort exit path.
    /// No reentrancy modifier here: the calling entrypoint holds the lock. Outsiders cannot use this hook.
    function claimPositionToSelf(address gauge, uint256 tokenId) external returns (uint256) {
        if (msg.sender != address(this)) revert OnlySelf();
        return _claimRewardsToSelf(gauge, tokenId);
    }

    function _claimRewardsToSelf(address gauge, uint256 tokenId) internal override returns (uint256 amount) {
        // Empty-NFT recovery isolates all previous owners' rewards before measuring this position's delta.
        _recoverDeferredRewards(gauge);
        uint256 beforeBalance = aeroToken.balanceOf(address(this));
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        IAeroGauge(gauge).claimEmissions(address(this), address(this), ids);
        if (IAeroGauge(gauge).deferredEmissions(address(this)) != 0) revert DeferredAccountingMismatch();
        amount = aeroToken.balanceOf(address(this)) - beforeBalance;
    }

    function _claimRewardsToSelfBestEffort(address gauge, uint256 tokenId) internal override returns (uint256 amount) {
        try this.claimPositionToSelf(gauge, tokenId) returns (uint256 claimed) {
            return claimed;
        } catch {
            // A withdrawal can still release the NFT and record the failed mint as an owner-attributed debt.
            return 0;
        }
    }

    function _recoverDeferredRewards(address gauge) internal returns (uint256 amount) {
        if (!knownGauges[gauge]) revert UnknownGauge();
        uint256 batch = currentDeferredBatch[gauge];
        DeferredBatch storage state = deferredBatches[gauge][batch];
        amount = state.amount;
        if (IAeroGauge(gauge).deferredEmissions(address(this)) != amount) revert DeferredAccountingMismatch();
        if (amount == 0) return 0;

        uint256 beforeBalance = aeroToken.balanceOf(address(this));
        IAeroGauge(gauge).claimEmissions(address(this), address(this), new uint256[](0));
        if (
            IAeroGauge(gauge).deferredEmissions(address(this)) != 0
                || aeroToken.balanceOf(address(this)) - beforeBalance != amount
        ) revert DeferredAccountingMismatch();
        state.recovered = true;
        reservedRewards += amount;
        currentDeferredBatch[gauge] = batch + 1;
        emit DeferredRewardsRecovered(gauge, batch, amount);
    }

    function _withdrawFromGauge(address gauge, uint256 tokenId, address owner) internal override {
        uint256 batch = currentDeferredBatch[gauge];
        uint256 deferredBefore = IAeroGauge(gauge).deferredEmissions(address(this));
        if (deferredBefore != deferredBatches[gauge][batch].amount) revert DeferredAccountingMismatch();

        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        uint256 token0Before = IERC20(token0).balanceOf(address(this));
        uint256 token1Before = IERC20(token1).balanceOf(address(this));
        IAeroGauge(gauge).withdraw(tokenId);

        uint256 newlyDeferred = IAeroGauge(gauge).deferredEmissions(address(this)) - deferredBefore;
        if (newlyDeferred != 0) {
            deferredBatches[gauge][batch].amount += newlyDeferred;
            deferredClaims[gauge][batch][owner] += newlyDeferred;
            emit DeferredRewardRecorded(gauge, batch, owner, tokenId, newlyDeferred);
        }

        // Aero withdraw can both mint rewards and collect NPM fees. Neither is protocol dust.
        // The receipt token may itself be a pool token: forward that balance delta once, never twice.
        _sendAeroIfAny(owner, aeroToken.balanceOf(address(this)) - aeroBefore);
        if (token0 != address(aeroToken)) {
            _sendTokenDelta(token0, owner, token0Before);
        }
        if (token1 != address(aeroToken)) {
            _sendTokenDelta(token1, owner, token1Before);
        }
    }

    function _sendTokenDelta(address token, address recipient, uint256 beforeBalance) private {
        uint256 amount = IERC20(token).balanceOf(address(this)) - beforeBalance;
        if (amount != 0) IERC20(token).safeTransfer(recipient, amount);
    }

    function withdrawBalances(address[] calldata tokens, address to) external override nonReentrant {
        if (msg.sender != withdrawer) revert Unauthorized();
        if (to == address(0)) revert InvalidConfig();
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = IERC20(tokens[i]);
            uint256 amount = token.balanceOf(address(this));
            if (tokens[i] == address(aeroToken)) amount -= reservedRewards;
            if (amount != 0) token.safeTransfer(to, amount);
        }
    }
}
