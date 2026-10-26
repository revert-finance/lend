// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/ICompoundRewardSource.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "./interfaces/aero/IAeroGauge.sol";
import "./utils/Swapper.sol";
import "./utils/AeroRewardDelivery.sol";

/// @notice Vault-only Aero staking adapter. Deferred rewards belong to the economic owner at withdrawal.
/// @dev A batch comprises one gauge's deferrals since its previous successful recovery. Recovery reserves
/// all claims in that batch without iterating owners. Root funding may still await minimum redemption. Claims survive NFT removal, transfer and liquidation.
/// `aeroToken` is the delivered asset: local receipts on leaf chains or AERO on the synchronous root chain.
/// Root sub-minimum rewards remain owner-bound liabilities until enough AERO has arrived to cover reserves.
/// Configured gauges and the immutable vault/token/NPM are trusted protocol dependencies.
contract GaugeManager is Ownable2Step, ReentrancyGuard, IERC721Receiver, Swapper, IGaugeManager {
    using SafeERC20 for IERC20;

    uint64 public constant MAX_REWARD_X64 = 1_844_674_407_370_955_161; // floor(Q64 / 10)
    // Reward compounding validates each fixed route hop against both TWAP deviation and a minimum output bound
    // derived from the current pool price before executing the swap.
    uint32 private constant REWARD_TWAP_SECONDS = 60;
    uint16 private constant REWARD_MAX_TWAP_TICK_DIFFERENCE = 200;
    uint64 private constant REWARD_MAX_PRICE_DIFFERENCE_X64 = 368_934_881_474_191_032; // floor(Q64 / 50)

    IERC20 public immutable aeroToken;
    IVault public immutable vault;
    address public override withdrawer;
    uint64 public totalRewardX64 = 368_934_881_474_191_032; // 2% (floor(Q64 / 50)): rate without a compound mode source
    // Answers the per-position reward rate (Simple / Advanced compound mode, see AutoRangeAndCompound); zero = every
    // compound pays totalRewardX64.
    address public override compoundModeSource;

    mapping(address => address) public override poolToGauge;
    mapping(uint256 => address) public override tokenIdToGauge;
    mapping(address => address) public override rewardBasePools;

    error DeferredAccountingMismatch();
    error UnknownGauge();
    error InsidePenaltyWindow();
    error OnlySelf();
    error NoDeferredClaim();
    error UnsupportedRewardDelivery();

    mapping(address => bool) public knownGauges;
    /// @dev Batches below the cursor are recovered (rootPendingBatches may still await funding); the cursor collects.
    mapping(address => uint256) public currentDeferredBatch;
    mapping(address => mapping(uint256 => uint256)) public deferredBatches;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public deferredClaims;

    /// @notice Shared root handler, bound on first root gauge registration; zero for direct leaf delivery.
    address public rootEmissionsHandler;
    mapping(address => uint256) public rootDeferredRewards;
    /// @dev A recovered gauge batch can itself be waiting for the root handler's minimum redemption amount.
    mapping(address => mapping(uint256 => bool)) public rootPendingBatches;

    event RootRewardDeferred(address indexed owner, uint256 indexed tokenId, uint256 amount);
    event RootRewardsClaimed(address indexed owner, address indexed recipient, uint256 amount);

    /// @notice User liabilities excluded from surplus; includes root rewards still awaiting redemption.
    uint256 public reservedRewards;

    event DeferredRewardRecorded(
        address indexed gauge, uint256 indexed batch, address indexed owner, uint256 tokenId, uint256 amount
    );
    event DeferredRewardsRecovered(address indexed gauge, uint256 indexed batch, uint256 amount);
    event DeferredBatchOutOfSync(address indexed gauge, uint256 indexed batch, uint256 recorded, uint256 upstream);
    event DeferredRewardsClaimed(
        address indexed gauge, uint256 indexed batch, address indexed owner, address recipient, uint256 amount
    );

    struct CompoundState {
        address gauge;
        address owner;
        address token0;
        address token1;
        IUniswapV3Pool positionPool;
        uint256 aeroAmount;
        uint256 spentAero;
        uint256 amount0Out;
        uint256 amount1Out;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint256 rewardAmount0;
        uint256 rewardAmount1;
    }

    struct RewardSwapValidation {
        address poolToken0;
        address poolToken1;
        bool swap0For1;
        uint160 sqrtPriceX96;
        uint256 amountOutMin;
        uint256 spotAmountOut;
    }

    constructor(
        INonfungiblePositionManager _npm,
        IERC20 _aeroToken,
        IVault _vault,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Swapper(_npm, _universalRouter, _zeroxAllowanceHolder) {
        if (address(_aeroToken) == address(0) || address(_vault) == address(0)) {
            revert InvalidConfig();
        }

        aeroToken = _aeroToken;
        vault = _vault;
        withdrawer = msg.sender;

        emit WithdrawerChanged(msg.sender);
    }

    function setGauge(address pool, address gauge) external override onlyOwner {
        if (pool == address(0) || gauge == address(0)) {
            revert InvalidConfig();
        }

        (bool success, bytes memory data) =
            pool.staticcall(abi.encodeWithSelector(IAerodromeSlipstreamPool.gauge.selector));
        if (!success || data.length < 32 || abi.decode(data, (address)) != gauge) {
            revert InvalidPool();
        }

        if (IAeroGauge(gauge).nft() != address(nonfungiblePositionManager) || IAeroGauge(gauge).pool() != pool) {
            revert InvalidPool();
        }
        address handler = AeroRewardDelivery.validate(gauge, address(aeroToken));
        if (handler != address(0)) {
            if (rootEmissionsHandler != address(0) && rootEmissionsHandler != handler) revert UnsupportedRewardDelivery();
            rootEmissionsHandler = handler;
        }
        // Keep previous gauges registered: their deferred claims survive a pool's gauge replacement.
        knownGauges[gauge] = true;

        poolToGauge[pool] = gauge;
        emit GaugeSet(pool, gauge);
    }

    function setRewardBasePool(address baseToken, address pool) external override onlyOwner {
        if (baseToken == address(0) || baseToken == address(aeroToken)) {
            revert InvalidConfig();
        }

        if (pool == address(0)) {
            delete rewardBasePools[baseToken];
            emit RewardBasePoolSet(baseToken, address(0));
            return;
        }

        IAerodromeSlipstreamPool slipstreamPool = IAerodromeSlipstreamPool(pool);
        address token0 = slipstreamPool.token0();
        address token1 = slipstreamPool.token1();
        if (!(token0 == address(aeroToken) && token1 == baseToken || token0 == baseToken && token1 == address(aeroToken)))
        {
            revert InvalidPool();
        }

        address resolved = IAerodromeSlipstreamFactory(factory).getPool(token0, token1, slipstreamPool.tickSpacing());
        if (resolved != pool) {
            revert InvalidPool();
        }

        rewardBasePools[baseToken] = pool;
        emit RewardBasePoolSet(baseToken, pool);
    }

    function setWithdrawer(address _withdrawer) external override onlyOwner {
        if (_withdrawer == address(0)) {
            revert InvalidConfig();
        }
        withdrawer = _withdrawer;
        emit WithdrawerChanged(_withdrawer);
    }

    function withdrawBalances(address[] calldata tokens, address to) external override nonReentrant {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }
        if (to == address(0)) revert InvalidConfig();

        uint256 i;
        uint256 count = tokens.length;
        address token;
        uint256 balance;
        for (; i < count; ++i) {
            token = tokens[i];
            balance = IERC20(token).balanceOf(address(this));
            if (token == address(aeroToken)) {
                // Root liabilities may not yet be in our balance. Never sweep funds backing them on later delivery.
                balance = rootEmissionsHandler != address(0) && balance < reservedRewards ? 0 : balance - reservedRewards;
            }
            if (balance != 0) {
                IERC20(token).safeTransfer(to, balance);
            }
        }
    }

    function withdrawETH(address to) external override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 balance = address(this).balance;
        if (balance != 0) {
            (bool sent,) = to.call{value: balance}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        }
    }

    function stakePosition(uint256 tokenId) external override nonReentrant {
        _requireVaultCaller();
        if (tokenIdToGauge[tokenId] != address(0)) {
            revert InvalidConfig();
        }

        address owner = vault.ownerOf(tokenId);
        if (owner == address(0)) {
            revert Unauthorized();
        }

        if (nonfungiblePositionManager.ownerOf(tokenId) != address(vault)) {
            revert Unauthorized();
        }

        (,, address token0, address token1, uint24 feeOrTickSpacing,,,,,,,) =
            nonfungiblePositionManager.positions(tokenId);

        IUniswapV3Pool pool = _getPool(token0, token1, feeOrTickSpacing);
        address gauge = poolToGauge[address(pool)];
        if (gauge == address(0)) {
            revert NotConfigured();
        }

        uint256 token0Before = IERC20(token0).balanceOf(address(this));
        uint256 token1Before = IERC20(token1).balanceOf(address(this));
        nonfungiblePositionManager.safeTransferFrom(address(vault), address(this), tokenId);
        nonfungiblePositionManager.approve(gauge, tokenId);
        IAeroGauge(gauge).deposit(tokenId);
        // Slipstream CLGauge.deposit triggers NPM.collect to msg.sender, so any pre-stake accrued token0/token1
        // fees are realized during staking and forwarded here to the position owner.
        _sendDepositDeltas(token0, token1, owner, token0Before, token1Before);

        // NOTE FOR AUDITS:
        // We intentionally do not enforce `ownerOf(tokenId) == gauge` post-deposit here.
        // Some gauge implementations may custody via intermediate contracts/wrappers while still exposing
        // the configured gauge as the canonical integration endpoint for claimEmissions/withdraw.
        // This is an accepted trust-boundary assumption on configured gauges.
        // Vault-side `_stake()` still enforces that custody leaves the vault to block no-op managers.
        tokenIdToGauge[tokenId] = gauge;
        emit PositionStaked(tokenId, owner, gauge);
    }

    function unstakePosition(uint256 tokenId) external override nonReentrant {
        _requireVaultCaller();

        bool wasStaked = _unstakePosition(tokenId);
        if (!wasStaked) {
            revert NotStaked();
        }
    }

    function unstakeIfStaked(uint256 tokenId) external override nonReentrant returns (bool wasStaked) {
        _requireVaultCaller();
        return _unstakePosition(tokenId);
    }

    function _unstakePosition(uint256 tokenId) internal returns (bool wasStaked) {
        address gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) {
            return false;
        }

        address owner = vault.ownerOf(tokenId);
        // Aero's withdraw already claims the position's net emissions to this contract or defers them.
        _withdrawFromGauge(gauge, tokenId, owner);
        nonfungiblePositionManager.safeTransferFrom(address(this), address(vault), tokenId, abi.encode(owner));
        delete tokenIdToGauge[tokenId];
        emit PositionUnstaked(tokenId, owner, gauge);
        return true;
    }

    function claimRewards(uint256 tokenId, address recipient)
        external
        override
        nonReentrant
        returns (uint256 aeroAmount)
    {
        address owner = _requireVaultOrOwner(tokenId);
        address gauge = _requireStakedGauge(tokenId);

        if (recipient == address(0)) {
            recipient = owner;
        }
        aeroAmount = _claimAndSendRewards(gauge, tokenId, owner, recipient);
        emit RewardsClaimed(tokenId, owner, aeroAmount);
    }

    function compoundRewards(
        uint256 tokenId,
        uint256 minAeroReward,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external override nonReentrant returns (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) {
        return _compoundRewards(tokenId, _requireVaultOrOwner(tokenId), minAeroReward, aeroSplitBps, deadline);
    }

    /// @notice Vault-only transform helper (compound-only policy): compound a staked position's rewards, then unstake.
    /// `strict` compounds with the given params and reverts if that fails; otherwise compounding is best-effort with
    /// defaults, and a failure (penalty window, missing route, empty claim, failed mint) falls back to the payout or
    /// deferral the unstake performs. Returns whether the position was staked, like unstakeIfStaked.
    function unstakeIfStakedCompounding(
        uint256 tokenId,
        bool strict,
        uint256 minAeroReward,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external override nonReentrant returns (bool wasStaked) {
        _requireVaultCaller();
        if (tokenIdToGauge[tokenId] == address(0)) {
            return false;
        }
        if (strict) {
            _compoundRewards(tokenId, vault.ownerOf(tokenId), minAeroReward, aeroSplitBps, deadline);
        } else {
            try this.compoundForVaultTransform(tokenId) {} catch {}
        }
        return _unstakePosition(tokenId);
    }

    /// @dev External self-call so a failed best-effort compound rolls back atomically. No reentrancy modifier: the
    /// vault entrypoint holds the lock, and nobody else can call this.
    function compoundForVaultTransform(uint256 tokenId) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _compoundRewards(tokenId, vault.ownerOf(tokenId), 0, 5000, block.timestamp);
    }

    function _compoundRewards(
        uint256 tokenId,
        address owner,
        uint256 minAeroReward,
        uint256 aeroSplitBps,
        uint256 deadline
    ) internal returns (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) {
        if (aeroSplitBps > 10_000) {
            revert InvalidConfig();
        }

        CompoundState memory state;
        state.gauge = _requireStakedGauge(tokenId);
        // Restaking resets the gauge's depositBlock, and any claim inside the window forfeits penaltyRate.
        if (block.number < _penaltyWindowEnd(state.gauge, tokenId)) revert InsidePenaltyWindow();
        uint24 feeOrTickSpacing;
        (,, state.token0, state.token1, feeOrTickSpacing,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        state.positionPool = _getPool(state.token0, state.token1, feeOrTickSpacing);
        state.owner = owner;

        state.aeroAmount = _claimRewardsToSelf(state.gauge, tokenId, owner);
        if (state.aeroAmount < minAeroReward) {
            revert NotEnoughReward();
        }
        if (state.aeroAmount == 0) {
            return (0, 0, 0);
        }

        _withdrawFromGauge(state.gauge, tokenId, state.owner);
        state = _swapAeroForPosition(state, aeroSplitBps);
        state = _addLiquidity(state, tokenId, deadline);
        uint256 token0BeforeDeposit = IERC20(state.token0).balanceOf(address(this));
        uint256 token1BeforeDeposit = IERC20(state.token1).balanceOf(address(this));
        nonfungiblePositionManager.approve(state.gauge, tokenId);
        IAeroGauge(state.gauge).deposit(tokenId);
        // Aerodrome deposit can realize NFT fees to msg.sender; forward those user-owned proceeds before
        // accounting for compounding leftovers so they do not become protocol-withdrawable dust.
        _sendDepositDeltas(state.token0, state.token1, state.owner, token0BeforeDeposit, token1BeforeDeposit);
        _sendLeftoversAndRewards(state);

        emit RewardsCompounded(tokenId, state.owner, state.aeroAmount, state.amountAdded0, state.amountAdded1);
        return (state.aeroAmount, state.amountAdded0, state.amountAdded1);
    }

    function setCompoundReward(uint64 _totalRewardX64) external override onlyOwner {
        if (_totalRewardX64 > totalRewardX64) {
            revert InvalidConfig();
        }
        totalRewardX64 = _totalRewardX64;
        emit CompoundRewardUpdated(msg.sender, _totalRewardX64);
    }

    /// @notice Owner sets the contract that answers each position's compound reward rate (AutoRangeAndCompound);
    /// zero disables it and every compound pays totalRewardX64 again.
    function setCompoundModeSource(address source) external override onlyOwner {
        compoundModeSource = source;
        emit CompoundModeSourceChanged(source);
    }

    /// @dev Reward rate for a compound of tokenId: the position's compound mode rate when a source is set and answers,
    /// capped at MAX_REWARD_X64; otherwise totalRewardX64. A failing source never blocks a compound.
    function _rewardRateX64(uint256 tokenId) internal view returns (uint64 rate) {
        rate = totalRewardX64;
        address source = compoundModeSource;
        if (source != address(0)) {
            try ICompoundRewardSource(source).compoundRewardX64(tokenId) returns (uint64 modeRate) {
                rate = modeRate > MAX_REWARD_X64 ? MAX_REWARD_X64 : modeRate;
            } catch {}
        }
    }

    /// @notice Recover a whole batch into escrow or root-pending reserves; never pays the caller or needs an NFT.
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
        // A claim only exists at or below the cursor, so this recovers the open batch or reverts.
        if (batch >= currentDeferredBatch[gauge]) _recoverDeferredRewards(gauge);
        if (rootPendingBatches[gauge][batch]) _requireRootRewardsFunded();
        delete deferredClaims[gauge][batch][msg.sender];
        reservedRewards -= amount;
        aeroToken.safeTransfer(recipient, amount);
        emit DeferredRewardsClaimed(gauge, batch, msg.sender, recipient, amount);
    }

    /// @notice Claims root sub-minimum rewards belonging to the caller, even after NFT exit or transfer.
    /// @dev Waits until all reserved liabilities are backed. Anyone may transfer AERO to cover residual dust;
    /// this does not grant them a claim or change the recorded owners.
    function claimRootDeferredRewards(address recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidConfig();
        amount = rootDeferredRewards[msg.sender];
        if (amount == 0) revert NoDeferredClaim();
        _requireRootRewardsFunded();
        delete rootDeferredRewards[msg.sender];
        reservedRewards -= amount;
        aeroToken.safeTransfer(recipient, amount);
        emit RootRewardsClaimed(msg.sender, recipient, amount);
    }

    function _requireRootRewardsFunded() internal view {
        if (aeroToken.balanceOf(address(this)) < reservedRewards) revert DeferredAccountingMismatch();
    }

    function _rootPending() internal view returns (uint256) {
        address handler = rootEmissionsHandler;
        return handler == address(0) ? 0 : IAeroRootEmissionsHandler(handler).pendingRedeems(address(this));
    }

    /// @dev Previously pending receipts pay one-for-one on local root redemption. They never belong to a new claim.
    function _recordRootDelivery(uint256 pendingBefore, address owner, uint256 tokenId)
        internal returns (uint256 previouslyPendingPaid)
    {
        uint256 pendingAfter = _rootPending();
        if (pendingAfter > pendingBefore) {
            uint256 amount = pendingAfter - pendingBefore;
            rootDeferredRewards[owner] += amount;
            reservedRewards += amount;
            emit RootRewardDeferred(owner, tokenId, amount);
        } else {
            previouslyPendingPaid = pendingBefore - pendingAfter;
        }
    }

    /// @notice Position earnings only. Aero's raw singleton earned() also includes account-wide deferrals.
    function positionRewards(uint256 tokenId) external view returns (uint256) {
        address gauge = _requireStakedGauge(tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        return IAeroGauge(gauge).earned(address(this), ids) - IAeroGauge(gauge).deferredEmissions(address(this));
    }

    /// @notice First block at which compounding no longer forfeits the gauge's early-unstake penalty; 0 if none applies.
    /// @dev Keepers should schedule compounds and restaking transforms at or after this block.
    function penaltyWindowEnd(uint256 tokenId) external view returns (uint256) {
        return _penaltyWindowEnd(_requireStakedGauge(tokenId), tokenId);
    }

    function _penaltyWindowEnd(address gauge, uint256 tokenId) internal view returns (uint256) {
        (uint256 minStakeBlocks, uint256 penaltyRate) =
            IAeroGaugeFactory(IAeroGauge(gauge).gaugeFactory()).effectivePenaltyConfig(gauge);
        return penaltyRate == 0 ? 0 : IAeroGauge(gauge).depositBlock(tokenId) + minStakeBlocks;
    }

    function _recoverDeferredRewards(address gauge) internal returns (uint256 amount) {
        if (!knownGauges[gauge]) revert UnknownGauge();
        uint256 batch = currentDeferredBatch[gauge];
        amount = deferredBatches[gauge][batch];
        if (IAeroGauge(gauge).deferredEmissions(address(this)) != amount) revert DeferredAccountingMismatch();
        if (amount == 0) return 0;

        uint256 beforeBalance = aeroToken.balanceOf(address(this));
        uint256 pendingBefore = _rootPending();
        IAeroGauge(gauge).claimEmissions(address(this), address(this), new uint256[](0));
        uint256 pendingAfter = _rootPending();
        if (
            IAeroGauge(gauge).deferredEmissions(address(this)) != 0
                || aeroToken.balanceOf(address(this)) - beforeBalance + pendingAfter != amount + pendingBefore
        ) revert DeferredAccountingMismatch();
        if (pendingAfter > pendingBefore) rootPendingBatches[gauge][batch] = true;
        reservedRewards += amount;
        currentDeferredBatch[gauge] = batch + 1;
        emit DeferredRewardsRecovered(gauge, batch, amount);
    }

    function _claimAndSendRewards(address gauge, uint256 tokenId, address owner, address recipient)
        internal
        returns (uint256 aeroAmount)
    {
        aeroAmount = _claimRewardsToSelf(gauge, tokenId, owner);
        _sendAeroIfAny(recipient, aeroAmount);
    }

    function _withdrawFromGauge(address gauge, uint256 tokenId, address owner) internal {
        uint256 batch = currentDeferredBatch[gauge];
        uint256 deferredBefore = IAeroGauge(gauge).deferredEmissions(address(this));
        // An exit never waits on bucket bookkeeping; recovery stays strict and surfaces any desync instead.
        if (deferredBefore != deferredBatches[gauge][batch]) {
            emit DeferredBatchOutOfSync(gauge, batch, deferredBatches[gauge][batch], deferredBefore);
        }

        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        uint256 pendingBefore = _rootPending();
        uint256 token0Before = IERC20(token0).balanceOf(address(this));
        uint256 token1Before = IERC20(token1).balanceOf(address(this));
        IAeroGauge(gauge).withdraw(tokenId);

        uint256 deferredAfter = IAeroGauge(gauge).deferredEmissions(address(this));
        uint256 newlyDeferred = deferredAfter > deferredBefore ? deferredAfter - deferredBefore : 0;
        if (newlyDeferred != 0) {
            deferredBatches[gauge][batch] += newlyDeferred;
            deferredClaims[gauge][batch][owner] += newlyDeferred;
            emit DeferredRewardRecorded(gauge, batch, owner, tokenId, newlyDeferred);
        }

        uint256 previouslyPendingPaid = _recordRootDelivery(pendingBefore, owner, tokenId);
        if (token0 == address(aeroToken)) token0Before += previouslyPendingPaid;
        if (token1 == address(aeroToken)) token1Before += previouslyPendingPaid;
        aeroBefore += previouslyPendingPaid;

        // Aero withdraw can both mint rewards and collect NPM fees. Neither is protocol dust.
        // The delivered reward token may itself be a pool token: forward that balance delta once, never twice.
        _sendDepositDeltas(token0, token1, owner, token0Before, token1Before);
        if (token0 != address(aeroToken) && token1 != address(aeroToken)) {
            uint256 aeroAfter = aeroToken.balanceOf(address(this));
            if (aeroAfter > aeroBefore) _sendAeroIfAny(owner, aeroAfter - aeroBefore);
        }
    }

    function _claimRewardsToSelf(address gauge, uint256 tokenId, address owner) internal returns (uint256 aeroAmount) {
        // Empty-NFT recovery isolates all previous owners' rewards before measuring this position's delta.
        _recoverDeferredRewards(gauge);
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        uint256 pendingBefore = _rootPending();
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        IAeroGauge(gauge).claimEmissions(address(this), address(this), ids);
        if (IAeroGauge(gauge).deferredEmissions(address(this)) != 0) revert DeferredAccountingMismatch();
        uint256 previouslyPendingPaid = _recordRootDelivery(pendingBefore, owner, tokenId);
        aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore - previouslyPendingPaid;
    }

    function _requireVaultCaller() internal view {
        if (msg.sender != address(vault)) {
            revert Unauthorized();
        }
    }

    function _requireVaultOrOwner(uint256 tokenId) internal returns (address owner) {
        owner = vault.ownerOf(tokenId);
        if (msg.sender != address(vault) && msg.sender != owner) {
            revert Unauthorized();
        }
    }

    function _requireStakedGauge(uint256 tokenId) internal view returns (address gauge) {
        gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) {
            revert NotStaked();
        }
    }

    function _sendAeroIfAny(address recipient, uint256 amount) internal {
        if (amount != 0) {
            aeroToken.safeTransfer(recipient, amount);
        }
    }

    function _sendDepositDeltas(
        address token0,
        address token1,
        address recipient,
        uint256 token0Before,
        uint256 token1Before
    ) internal {
        uint256 token0After = IERC20(token0).balanceOf(address(this));
        uint256 token1After = IERC20(token1).balanceOf(address(this));
        if (token0After > token0Before) {
            IERC20(token0).safeTransfer(recipient, token0After - token0Before);
        }
        if (token1After > token1Before) {
            IERC20(token1).safeTransfer(recipient, token1After - token1Before);
        }
    }

    function _swapAeroForPosition(
        CompoundState memory state,
        uint256 aeroSplitBps
    ) internal returns (CompoundState memory) {
        uint256 requestedAero0 = state.aeroAmount * aeroSplitBps / 10_000;
        uint256 requestedAero1 = state.aeroAmount - requestedAero0;

        // The requested amounts are upper bounds: a pool can exhaust its liquidity before the limit price and
        // consume less input while its output still clears the validated minimum. Only what the pools actually
        // consumed counts as spent, so every unconsumed receipt token flows back to the owner as leftover, and
        // the unconsumed input of a two-hop second hop (the other position token) is accounted as its output.
        (uint256 spentAero0, uint256 amount0Out, uint256 unconsumed1) =
            _swapAeroToTarget(state.positionPool, state.token0, state.token1, requestedAero0);
        (uint256 spentAero1, uint256 amount1Out, uint256 unconsumed0) =
            _swapAeroToTarget(state.positionPool, state.token1, state.token0, requestedAero1);

        state.spentAero = spentAero0 + spentAero1;
        state.amount0Out = amount0Out + unconsumed0;
        state.amount1Out = amount1Out + unconsumed1;
        return state;
    }

    /// @return spentAero receipt tokens the route actually consumed (at most `amountIn`)
    /// @return amountOut target tokens received
    /// @return unconsumedOther `otherToken` left over when the second hop of the two-hop route stops early
    function _swapAeroToTarget(IUniswapV3Pool positionPool, address targetToken, address otherToken, uint256 amountIn)
        internal
        returns (uint256 spentAero, uint256 amountOut, uint256 unconsumedOther)
    {
        if (amountIn == 0) {
            return (0, 0, 0);
        }

        if (targetToken == address(aeroToken)) {
            return (amountIn, amountIn, 0);
        }

        address directPool = rewardBasePools[targetToken];
        if (directPool != address(0)) {
            (spentAero, amountOut) =
                _swapThroughPool(IUniswapV3Pool(directPool), address(aeroToken), targetToken, amountIn);
            return (spentAero, amountOut, 0);
        }

        address intermediatePool = rewardBasePools[otherToken];
        if (intermediatePool == address(0)) {
            revert NotConfigured();
        }

        IUniswapV3Pool intermediateRewardPool = IUniswapV3Pool(intermediatePool);
        RewardSwapValidation memory intermediateValidation =
            _validateRewardSwap(intermediateRewardPool, address(aeroToken), otherToken, amountIn);
        uint256 intermediateAmount;
        (spentAero, intermediateAmount) = _swapThroughValidatedPool(
            intermediateRewardPool, intermediateValidation, amountIn, intermediateValidation.amountOutMin
        );

        // The second hop swaps what the first hop actually produced. The combined-route minimum still prices the
        // full requested input, so a short first hop is only accepted within the single route tolerance.
        RewardSwapValidation memory targetValidation =
            _validateRewardSwap(positionPool, otherToken, targetToken, intermediateAmount);
        uint256 routeAmountOutMin = _combinedRouteAmountOutMin(intermediateValidation, targetValidation);
        uint256 targetAmountOutMin =
            targetValidation.amountOutMin > routeAmountOutMin ? targetValidation.amountOutMin : routeAmountOutMin;

        uint256 spentIntermediate;
        (spentIntermediate, amountOut) =
            _swapThroughValidatedPool(positionPool, targetValidation, intermediateAmount, targetAmountOutMin);
        unconsumedOther = intermediateAmount - spentIntermediate;
    }

    function _swapThroughPool(IUniswapV3Pool pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountInDelta, uint256 amountOut)
    {
        if (amountIn == 0) {
            return (0, 0);
        }

        RewardSwapValidation memory validation = _validateRewardSwap(pool, tokenIn, tokenOut, amountIn);
        (amountInDelta, amountOut) = _swapThroughValidatedPool(pool, validation, amountIn, validation.amountOutMin);
    }

    /// @dev Returns the input the pool actually consumed next to the output; `_poolSwap` already enforces
    /// `amountOutMin` on the output.
    function _swapThroughValidatedPool(
        IUniswapV3Pool pool,
        RewardSwapValidation memory validation,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 amountInDelta, uint256 amountOut) {
        if (amountIn == 0) {
            return (0, 0);
        }

        (amountInDelta, amountOut) = _poolSwap(
            PoolSwapParams({
                pool: pool,
                token0: IERC20(validation.poolToken0),
                token1: IERC20(validation.poolToken1),
                fee: _poolFeeOrTickSpacing(pool),
                swap0For1: validation.swap0For1,
                amountIn: amountIn,
                amountOutMin: amountOutMin
            })
        );
    }

    function _validateRewardSwap(IUniswapV3Pool pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (RewardSwapValidation memory validation)
    {
        validation.poolToken0 = IAerodromeSlipstreamPool(address(pool)).token0();
        validation.poolToken1 = IAerodromeSlipstreamPool(address(pool)).token1();
        if (validation.poolToken0 == tokenIn && validation.poolToken1 == tokenOut) {
            validation.swap0For1 = true;
        } else if (validation.poolToken0 == tokenOut && validation.poolToken1 == tokenIn) {
            validation.swap0For1 = false;
        } else {
            revert InvalidPool();
        }

        int24 currentTick;
        (validation.sqrtPriceX96, currentTick) = _getPoolSlot0(pool);
        // full-precision spot quote (the bound with zero tolerance), the base of the two-hop route bound
        validation.spotAmountOut = _calculateAmountOutMin(validation.swap0For1, amountIn, validation.sqrtPriceX96, 0);
        validation.amountOutMin = _positiveQuoteMinimum(
            _validateSwap(
                validation.swap0For1,
                amountIn,
                pool,
                currentTick,
                validation.sqrtPriceX96,
                REWARD_TWAP_SECONDS,
                REWARD_MAX_TWAP_TICK_DIFFERENCE,
                REWARD_MAX_PRICE_DIFFERENCE_X64
            ),
            validation.spotAmountOut
        );
    }

    function _combinedRouteAmountOutMin(
        RewardSwapValidation memory intermediateValidation,
        RewardSwapValidation memory targetValidation
    ) internal pure returns (uint256 amountOutMin) {
        // Apply the reward tolerance once to the full two-hop spot quote so per-hop bounds cannot compound. The quote
        // uses the same full-precision arithmetic as each hop's own bound (Swapper._calculateAmountOutMin with zero
        // tolerance): squaring the sqrt price down to Q96 first floored valid second-hop prices below 2^-96 to zero,
        // which dropped this route bound and let both per-hop tolerances compound (Cantina LEND-77).
        uint256 routeSpotAmountOut = _calculateAmountOutMin(
            targetValidation.swap0For1, intermediateValidation.spotAmountOut, targetValidation.sqrtPriceX96, 0
        );
        amountOutMin = _positiveQuoteMinimum(
            FullMath.mulDiv(routeSpotAmountOut, Q64 - REWARD_MAX_PRICE_DIFFERENCE_X64, Q64), routeSpotAmountOut
        );
    }

    /// @dev A positive quote never tolerates an empty output: the tolerance rounds a one-unit quote down to zero, and a
    /// fee-bearing pool would then consume the whole input for nothing (Cantina LEND-128).
    function _positiveQuoteMinimum(uint256 amountOutMin, uint256 spotAmountOut) internal pure returns (uint256) {
        return amountOutMin == 0 && spotAmountOut != 0 ? 1 : amountOutMin;
    }

    function _poolFeeOrTickSpacing(IUniswapV3Pool pool) internal view returns (uint24 feeOrTickSpacing) {
        int24 tickSpacing = IAerodromeSlipstreamPool(address(pool)).tickSpacing();
        if (tickSpacing <= 0) {
            revert InvalidPool();
        }
        assembly ("memory-safe") {
            feeOrTickSpacing := tickSpacing
        }
    }

    function _addLiquidity(CompoundState memory state, uint256 tokenId, uint256 deadline)
        internal
        returns (CompoundState memory)
    {
        uint256 rewardX64 = _rewardRateX64(tokenId);
        state.maxAddAmount0 = state.amount0Out * Q64 / (rewardX64 + Q64);
        state.maxAddAmount1 = state.amount1Out * Q64 / (rewardX64 + Q64);

        if (state.maxAddAmount0 != 0) {
            IERC20(state.token0).safeIncreaseAllowance(address(nonfungiblePositionManager), state.maxAddAmount0);
        }
        if (state.maxAddAmount1 != 0) {
            IERC20(state.token1).safeIncreaseAllowance(address(nonfungiblePositionManager), state.maxAddAmount1);
        }

        if (state.maxAddAmount0 != 0 || state.maxAddAmount1 != 0) {
            (, state.amountAdded0, state.amountAdded1) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId, state.maxAddAmount0, state.maxAddAmount1, 0, 0, deadline
                )
            );
            state.rewardAmount0 = state.amountAdded0 * rewardX64 / Q64;
            state.rewardAmount1 = state.amountAdded1 * rewardX64 / Q64;
        }

        if (state.maxAddAmount0 != 0) {
            IERC20(state.token0).safeApprove(address(nonfungiblePositionManager), 0);
        }
        if (state.maxAddAmount1 != 0) {
            IERC20(state.token1).safeApprove(address(nonfungiblePositionManager), 0);
        }

        return state;
    }

    function _sendLeftoversAndRewards(CompoundState memory state) internal {
        uint256 leftoverAero = state.aeroAmount - state.spentAero;
        if (leftoverAero != 0) {
            aeroToken.safeTransfer(state.owner, leftoverAero);
        }

        uint256 leftover0 = state.amount0Out - state.amountAdded0 - state.rewardAmount0;
        uint256 leftover1 = state.amount1Out - state.amountAdded1 - state.rewardAmount1;
        if (leftover0 != 0) {
            IERC20(state.token0).safeTransfer(state.owner, leftover0);
        }
        if (leftover1 != 0) {
            IERC20(state.token1).safeTransfer(state.owner, leftover1);
        }
        // protocol rewards (rewardAmount0/rewardAmount1) remain in this contract and can be collected
        // through withdrawBalances by the configured withdrawer.
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }
        // Accept only protocol-managed custody hops:
        // - Vault -> GaugeManager during stake flow (mapping not set yet)
        // - Gauge -> GaugeManager during unstake flow (mapping points to source gauge)
        if (from != address(vault) && from != tokenIdToGauge[tokenId]) {
            revert Unauthorized();
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
