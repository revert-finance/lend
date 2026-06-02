// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./Automator.sol";

/// @dev Minimal PancakeSwap MasterChefV3 surface used by this compoundor.
interface IPancakeMasterChefV3 {
    function CAKE() external view returns (address);
    function nonfungiblePositionManager() external view returns (address);
    function harvest(uint256 tokenId, address to) external returns (uint256 reward);
    function withdraw(uint256 tokenId, address to) external returns (uint256 reward);
    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @notice Shared PancakeSwap MasterChefV3 compoundor for staked V3 NFT autocompounding and review-stage transforms.
/// @dev MasterChef gates harvest/collect/withdraw/decrease actions by its recorded user, not by ERC721 approval.
///      This contract therefore receives each NFT first, stakes it from this address, and tracks the real owner here.
contract PancakeMasterChefV3Compoundor is Automator, Multicall, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Maximum protocol reward kept from amounts added back into the position.
    uint64 public constant MAX_REWARD_X64 = 368934881474191032; // 2%
    /// @notice Maximum tolerated spot/TWAP difference used for CAKE and balancing swaps.
    uint64 public constant REWARD_MAX_PRICE_DIFFERENCE_X64 = 368934881474191032; // 2%

    IERC20 public immutable cakeToken;
    IPancakeMasterChefV3 public immutable masterChef;

    /// @notice Protocol reward rate in Q64, charged on amounts successfully added as liquidity.
    uint64 public totalRewardX64 = MAX_REWARD_X64;
    /// @notice Active transform token id; also lets existing transformers treat this contract as a vault.
    uint256 public transformedTokenId;

    /// @notice Logical owner of each position managed by the compoundor.
    mapping(uint256 => address) public positionOwners;
    /// @notice Anchor token configs used to validate dynamic CAKE reward routes.
    mapping(address => AnchorConfig) public rewardAnchors;
    mapping(address => uint256[]) private ownedTokens;
    mapping(uint256 => uint256) private ownedTokensIndex;

    event RewardAnchorSet(address indexed anchorToken, uint256 anchorTokenMinBalance, bool active);
    event PositionStaked(uint256 indexed tokenId, address indexed owner, address indexed masterChef);
    event PositionRestaked(uint256 indexed tokenId, address indexed owner, address indexed masterChef);
    event PositionUnstaked(
        uint256 indexed tokenId, address indexed owner, address indexed recipient, uint256 cakeAmount
    );
    event TransformExecuted(
        uint256 indexed tokenId, address indexed owner, address indexed transformer, uint256 cakeAmount
    );
    event RewardsClaimed(uint256 indexed tokenId, address indexed owner, address indexed recipient, uint256 cakeAmount);
    event AutoCompounded(
        address account,
        uint256 tokenId,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1
    );
    event RewardUpdated(address account, uint64 totalRewardX64);
    event LeftoverSent(uint256 indexed tokenId, address indexed token, address indexed to, uint256 amount);

    /// @notice Parameters for owner/operator compounding.
    /// @dev The operator supplies swap amounts and pools, but every pool is validated as the canonical V3 pool and
    ///      every swap is checked against current spot/TWAP bounds before execution.
    struct CompoundParams {
        // Staked MasterChef token id to compound.
        uint256 tokenId;
        // Revert if harvested CAKE is lower than this amount.
        uint256 minCakeReward;
        // Percentage of harvested CAKE routed toward token0; the rest routes toward token1.
        uint256 cakeSplitBps;
        // CAKE/anchor or CAKE/token0 pool used for the token0 reward route.
        IUniswapV3Pool token0CakePool;
        // token0/anchor pool used when token0 is not itself an active anchor.
        IUniswapV3Pool token0AnchorPool;
        // CAKE/anchor or CAKE/token1 pool used for the token1 reward route.
        IUniswapV3Pool token1CakePool;
        // token1/anchor pool used when token1 is not itself an active anchor.
        IUniswapV3Pool token1AnchorPool;
        // Optional same-pool balancing swap direction between the position tokens.
        bool pairSwap0For1;
        // Optional same-pool balancing swap amount.
        uint256 pairSwapAmountIn;
        // Optional stricter min-out for the balancing swap.
        uint256 pairSwapAmountOutMin;
        // Min amounts for the final MasterChef increaseLiquidity call.
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Anchor token whitelist entry.
    /// @dev anchorTokenMinBalance is checked against the supplied CAKE/anchor pool balance to reject thin anchors.
    struct AnchorConfig {
        bool active;
        uint256 anchorTokenMinBalance;
    }

    /// @dev Scratch state for a compound. The balance snapshots protect pre-existing protocol balances from being
    ///      treated as owner leftovers when token0/token1/CAKE are already held by the contract.
    struct CompoundState {
        address owner;
        address token0;
        address token1;
        IUniswapV3Pool positionPool;
        uint256 cakeAmount;
        uint256 spentCake;
        uint256 amount0;
        uint256 amount1;
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint256 rewardAmount0;
        uint256 rewardAmount1;
        uint256 balance0Before;
        uint256 balance1Before;
        uint256 cakeBalanceBefore;
    }

    /// @dev Validated pool metadata and price-derived min-out used immediately before a reward swap.
    struct RewardSwapValidation {
        address poolToken0;
        address poolToken1;
        bool swap0For1;
        uint160 sqrtPriceX96;
        uint256 amountOutMin;
        uint256 spotAmountOut;
    }

    constructor(
        INonfungiblePositionManager npm,
        IPancakeMasterChefV3 _masterChef,
        IERC20 _cakeToken,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder
    )
        Automator(
            npm, _operator, _withdrawer, _TWAPSeconds, _maxTWAPTickDifference, _universalRouter, _zeroxAllowanceHolder
        )
    {
        if (address(_masterChef) == address(0) || address(_cakeToken) == address(0)) {
            revert InvalidConfig();
        }
        if (_masterChef.CAKE() != address(_cakeToken) || _masterChef.nonfungiblePositionManager() != address(npm)) {
            revert InvalidConfig();
        }

        masterChef = _masterChef;
        cakeToken = _cakeToken;
    }

    /// @notice Returns the logical owner recorded by this compoundor.
    function ownerOf(uint256 tokenId) external view returns (address owner) {
        owner = positionOwners[tokenId];
    }

    /// @notice Number of managed positions recorded for an owner.
    function positionCount(address owner) external view returns (uint256) {
        return ownedTokens[owner].length;
    }

    /// @notice Managed token id at an owner's enumerable index.
    function positionAtIndex(address owner, uint256 index) external view returns (uint256) {
        return ownedTokens[owner][index];
    }

    /// @notice Adds, updates, or removes an anchor token accepted for dynamic CAKE reward routes.
    /// @dev Set anchorTokenMinBalance to zero to remove the anchor.
    function setRewardAnchor(address anchorToken, uint256 anchorTokenMinBalance) external onlyOwner {
        if (anchorToken == address(0) || anchorToken == address(cakeToken)) {
            revert InvalidConfig();
        }

        if (anchorTokenMinBalance == 0) {
            delete rewardAnchors[anchorToken];
            emit RewardAnchorSet(anchorToken, 0, false);
            return;
        }

        rewardAnchors[anchorToken] = AnchorConfig({active: true, anchorTokenMinBalance: anchorTokenMinBalance});
        emit RewardAnchorSet(anchorToken, anchorTokenMinBalance, true);
    }

    /// @notice Sets protocol reward kept from amounts added during compounding.
    function setReward(uint64 _totalRewardX64) external onlyOwner {
        if (_totalRewardX64 > MAX_REWARD_X64) {
            revert InvalidConfig();
        }
        totalRewardX64 = _totalRewardX64;
        emit RewardUpdated(msg.sender, _totalRewardX64);
    }

    /// @notice Transfers a Pancake V3 NFT into this contract and stakes it into MasterChef for recipient.
    /// @dev Users may also call safeTransferFrom directly; this helper exists for explicit recipient selection.
    function stakePosition(uint256 tokenId, address recipient) external nonReentrant {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(recipient));
    }

    /// @notice Withdraws a managed position to recipient.
    /// @dev Non-empty positions are normally staked. If a non-empty NFT is found locally, it is restaked instead of
    ///      withdrawn; only empty local residual positions can be transferred out directly.
    function unstakePosition(uint256 tokenId, address recipient) external nonReentrant returns (uint256 cakeAmount) {
        address owner = _requirePositionOwner(tokenId);
        if (recipient == address(0)) {
            recipient = owner;
        }

        address nftOwner = _nftOwnerOrZero(tokenId);
        if (nftOwner == address(masterChef)) {
            if (recipient == address(this)) {
                revert InvalidConfig();
            }
            _removePositionFromOwner(owner, tokenId);
            cakeAmount = masterChef.withdraw(tokenId, recipient);
            emit PositionUnstaked(tokenId, owner, recipient, cakeAmount);
            return cakeAmount;
        }
        if (nftOwner != address(this)) {
            revert NotConfigured();
        }
        if (_positionLiquidity(tokenId) != 0) {
            _stakeFromVault(tokenId);
            emit PositionRestaked(tokenId, owner, address(masterChef));
            return 0;
        }

        _removePositionFromOwner(owner, tokenId);
        nonfungiblePositionManager.safeTransferFrom(address(this), recipient, tokenId);

        emit PositionUnstaked(tokenId, owner, recipient, cakeAmount);
    }

    /// @notice Harvests CAKE rewards for a staked position to recipient.
    function claimRewards(uint256 tokenId, address recipient) external nonReentrant returns (uint256 cakeAmount) {
        address owner = _requireStakedOwnerCaller(tokenId);
        if (recipient == address(0)) {
            recipient = owner;
        }

        cakeAmount = masterChef.harvest(tokenId, recipient);
        emit RewardsClaimed(tokenId, owner, recipient, cakeAmount);
    }

    /// @notice Owner-called compound for a staked position.
    function compound(CompoundParams calldata params)
        external
        nonReentrant
        returns (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1)
    {
        address owner = _requireStakedOwnerCaller(params.tokenId);
        return _compound(params, owner);
    }

    /// @notice Operator entrypoint matching the rest of the automator `execute` pattern.
    /// @dev Operators can execute the same compound logic as owners but never choose recipients.
    function execute(CompoundParams calldata params)
        external
        nonReentrant
        returns (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1)
    {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }
        address owner = _requireStakedPosition(params.tokenId);
        return _compound(params, owner);
    }

    /// @notice Temporarily withdraws a staked position, lets a transformer operate, and restakes results.
    /// @dev Only the position owner can call this function.
    /// @dev Any NFT received from the transformer during this call is assigned to the same owner and immediately
    ///      staked. Transformers must send non-original-token leftovers directly to the owner; this contract only
    ///      sweeps balance increases of the original token0/token1/CAKE.
    function transform(uint256 tokenId, address transformer, bytes calldata data)
        external
        nonReentrant
    {
        if (tokenId == 0 || transformer == address(0)) {
            revert TransformNotAllowed();
        }
        if (transformedTokenId != 0) {
            revert Reentrancy();
        }

        address owner = _requireStakedOwnerCaller(tokenId);

        transformedTokenId = tokenId;

        // MasterChef withdraw also harvests CAKE. Send it to the owner before transformer execution.
        uint256 cakeAmount = _withdrawToSelf(tokenId);
        if (cakeAmount != 0) {
            cakeToken.safeTransfer(owner, cakeAmount);
        }

        // Snapshot only the original position tokens and CAKE. Other leftovers are transformer responsibility.
        (address token0, address token1,,) = _positionPoolInfo(tokenId);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        uint256 cakeBalanceBefore = cakeToken.balanceOf(address(this));

        nonfungiblePositionManager.approve(transformer, tokenId);

        (bool success,) = transformer.call(data);
        if (!success) {
            revert TransformFailed();
        }

        // The original token id may be empty after transform, but if it still has liquidity it must be staked again.
        _finalizeTransformPosition(tokenId);

        transformedTokenId = 0;
        _sweepOriginalTransformTokens(tokenId, owner, token0, token1, balance0Before, balance1Before, cakeBalanceBefore);

        emit TransformExecuted(tokenId, owner, transformer, cakeAmount);
    }

    function _requirePositionOwner(uint256 tokenId) internal view returns (address owner) {
        owner = positionOwners[tokenId];
        if (owner == address(0)) {
            revert NotConfigured();
        }
        if (msg.sender != owner) {
            revert Unauthorized();
        }
    }

    function _requireStakedPosition(uint256 tokenId) internal view returns (address owner) {
        owner = positionOwners[tokenId];
        if (owner == address(0)) {
            revert NotConfigured();
        }
        if (_nftOwnerOrZero(tokenId) != address(masterChef)) {
            revert NotConfigured();
        }
    }

    function _requireStakedOwnerCaller(uint256 tokenId) internal view returns (address owner) {
        owner = _requireStakedPosition(tokenId);
        if (msg.sender != owner) {
            revert Unauthorized();
        }
    }

    /// @dev Records the logical owner and maintains O(1) owner-position enumeration.
    function _addPositionToOwner(address owner, uint256 tokenId) internal {
        if (owner == address(0) || positionOwners[tokenId] != address(0)) {
            revert InvalidConfig();
        }

        positionOwners[tokenId] = owner;
        ownedTokensIndex[tokenId] = ownedTokens[owner].length;
        ownedTokens[owner].push(tokenId);
    }

    /// @dev Clears logical ownership and removes tokenId from the owner's enumerable set with swap-and-pop.
    function _removePositionFromOwner(address owner, uint256 tokenId) internal {
        if (positionOwners[tokenId] != owner) {
            revert Unauthorized();
        }

        uint256 lastTokenIndex = ownedTokens[owner].length - 1;
        uint256 tokenIndex = ownedTokensIndex[tokenId];
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedTokens[owner][lastTokenIndex];
            ownedTokens[owner][tokenIndex] = lastTokenId;
            ownedTokensIndex[lastTokenId] = tokenIndex;
        }

        ownedTokens[owner].pop();
        delete ownedTokensIndex[tokenId];
        delete positionOwners[tokenId];
    }

    function _compound(CompoundParams calldata params, address owner)
        internal
        returns (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1)
    {
        CompoundState memory state;
        state.owner = owner;
        if (params.cakeSplitBps > 10_000) {
            revert InvalidConfig();
        }

        (state.token0, state.token1,, state.positionPool) = _positionPoolInfo(params.tokenId);
        // Existing balances may include protocol fees from earlier compounds. Snapshot before pulling new funds.
        state.balance0Before = IERC20(state.token0).balanceOf(address(this));
        state.balance1Before = IERC20(state.token1).balanceOf(address(this));
        state.cakeBalanceBefore = cakeToken.balanceOf(address(this));

        state.cakeAmount = _claimRewardsToSelf(params.tokenId);
        if (state.cakeAmount < params.minCakeReward) {
            revert NotEnoughReward();
        }

        (uint256 collected0, uint256 collected1) = masterChef.collect(
            INonfungiblePositionManager.CollectParams(
                params.tokenId, address(this), type(uint128).max, type(uint128).max
            )
        );
        state.amount0 += collected0;
        state.amount1 += collected1;

        state = _swapCakeForPosition(state, params);
        state = _swapPositionTokens(state, params);
        state = _addLiquidity(state, params);
        _sendLeftovers(params.tokenId, state);

        emit AutoCompounded(
            msg.sender,
            params.tokenId,
            state.amountAdded0,
            state.amountAdded1,
            state.rewardAmount0,
            state.rewardAmount1,
            state.token0,
            state.token1
        );
        return (state.cakeAmount, state.amountAdded0, state.amountAdded1);
    }

    /// @dev Reads position tokens and resolves the corresponding canonical pool.
    function _positionPoolInfo(uint256 tokenId)
        internal
        view
        returns (address token0, address token1, uint24 fee, IUniswapV3Pool pool)
    {
        (,, token0, token1, fee,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        pool = _getPool(token0, token1, fee);
    }

    /// @dev Reads only the current liquidity field from the NFT position.
    function _positionLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
    }

    function _getPoolSlot0(IUniswapV3Pool pool) internal view returns (uint160 sqrtPriceX96, int24 currentTick) {
        (sqrtPriceX96, currentTick,,,,,) = pool.slot0();
    }

    /// @dev Validates that a supplied CAKE/anchor pool is canonical and deep enough in anchor-token units.
    function _validateCakeAnchorPool(
        address anchorToken,
        IUniswapV3Pool cakePool,
        AnchorConfig memory anchor
    ) internal view {
        if (address(cakePool) == address(0)) {
            revert NotConfigured();
        }

        address token0 = cakePool.token0();
        address token1 = cakePool.token1();
        if (
            !(token0 == address(cakeToken) && token1 == anchorToken || token0 == anchorToken
                && token1 == address(cakeToken))
        ) {
            revert InvalidPool();
        }
        _validateCanonicalPool(cakePool, token0, token1);
        if (IERC20(anchorToken).balanceOf(address(cakePool)) < anchor.anchorTokenMinBalance) {
            revert InsufficientLiquidity();
        }
    }

    /// @dev Finds the configured anchor token from a supplied target/anchor pool.
    function _validateTargetAnchorPool(address targetToken, IUniswapV3Pool targetAnchorPool)
        internal
        view
        returns (address anchorToken, AnchorConfig memory anchor)
    {
        if (address(targetAnchorPool) == address(0)) {
            revert NotConfigured();
        }

        address token0 = targetAnchorPool.token0();
        address token1 = targetAnchorPool.token1();
        if (token0 == targetToken) {
            anchorToken = token1;
        } else if (token1 == targetToken) {
            anchorToken = token0;
        } else {
            revert InvalidPool();
        }

        anchor = rewardAnchors[anchorToken];
        if (!anchor.active) {
            revert NotConfigured();
        }

        _validateCanonicalPool(targetAnchorPool, token0, token1);
    }

    /// @dev Rejects spoofed pool addresses by resolving the pool from the factory.
    function _validateCanonicalPool(IUniswapV3Pool pool, address token0, address token1) internal view {
        if (address(pool) == address(0) || address(_getPool(token0, token1, pool.fee())) != address(pool)) {
            revert InvalidPool();
        }
    }

    /// @dev Stakes an NFT owned by this contract. MasterChef records this contract as the position user.
    function _stakeFromVault(uint256 tokenId) internal {
        nonfungiblePositionManager.safeTransferFrom(address(this), address(masterChef), tokenId);
        if (nonfungiblePositionManager.ownerOf(tokenId) != address(masterChef)) {
            revert InvalidConfig();
        }
    }

    /// @dev Restakes the original transform token if it still has liquidity after transformer execution.
    function _finalizeTransformPosition(uint256 tokenId) internal {
        address nftOwner = _nftOwnerOrZero(tokenId);
        if (nftOwner == address(masterChef)) {
            return;
        }
        if (nftOwner != address(this)) {
            revert Unauthorized();
        }

        nonfungiblePositionManager.approve(address(0), tokenId);
        if (_positionLiquidity(tokenId) != 0) {
            address owner = positionOwners[tokenId];
            _stakeFromVault(tokenId);
            emit PositionRestaked(tokenId, owner, address(masterChef));
        }
    }

    /// @dev Withdraws to this contract and returns only the CAKE balance increase, protecting existing CAKE.
    function _withdrawToSelf(uint256 tokenId) internal returns (uint256 cakeAmount) {
        uint256 cakeBefore = cakeToken.balanceOf(address(this));
        masterChef.withdraw(tokenId, address(this));
        cakeAmount = _balanceIncrease(address(cakeToken), cakeBefore);
    }

    /// @dev Harvests to this contract and returns only the CAKE balance increase, protecting existing CAKE.
    function _claimRewardsToSelf(uint256 tokenId) internal returns (uint256 cakeAmount) {
        uint256 cakeBefore = cakeToken.balanceOf(address(this));
        masterChef.harvest(tokenId, address(this));
        cakeAmount = _balanceIncrease(address(cakeToken), cakeBefore);
    }

    /// @dev Splits harvested CAKE into the operator-selected token0/token1 routes.
    function _swapCakeForPosition(CompoundState memory state, CompoundParams calldata params)
        internal
        returns (CompoundState memory)
    {
        uint256 requestedCake0 = state.cakeAmount * params.cakeSplitBps / 10_000;
        uint256 requestedCake1 = state.cakeAmount - requestedCake0;

        (uint256 spentCake0, uint256 amount0Out) =
            _swapCakeToTarget(state.token0, params.token0CakePool, params.token0AnchorPool, requestedCake0);
        (uint256 spentCake1, uint256 amount1Out) =
            _swapCakeToTarget(state.token1, params.token1CakePool, params.token1AnchorPool, requestedCake1);

        state.spentCake = spentCake0 + spentCake1;
        state.amount0 += amount0Out;
        state.amount1 += amount1Out;
        return state;
    }

    /// @dev Swaps CAKE directly to an active anchor token or through CAKE/anchor plus target/anchor pools.
    function _swapCakeToTarget(
        address targetToken,
        IUniswapV3Pool cakeAnchorPool,
        IUniswapV3Pool targetAnchorPool,
        uint256 amountIn
    )
        internal
        returns (uint256 spentCake, uint256 amountOut)
    {
        if (amountIn == 0) {
            return (0, 0);
        }

        if (targetToken == address(cakeToken)) {
            return (amountIn, amountIn);
        }

        AnchorConfig memory directAnchor = rewardAnchors[targetToken];
        if (directAnchor.active) {
            _validateCakeAnchorPool(targetToken, cakeAnchorPool, directAnchor);
            RewardSwapValidation memory directValidation =
                _validateRewardSwap(cakeAnchorPool, address(cakeToken), targetToken, amountIn);
            amountOut = _swapThroughValidatedPool(
                cakeAnchorPool, directValidation, amountIn, directValidation.amountOutMin
            );
            return (amountIn, amountOut);
        }

        (address anchorToken, AnchorConfig memory anchor) = _validateTargetAnchorPool(targetToken, targetAnchorPool);
        _validateCakeAnchorPool(anchorToken, cakeAnchorPool, anchor);
        RewardSwapValidation memory intermediateValidation =
            _validateRewardSwap(cakeAnchorPool, address(cakeToken), anchorToken, amountIn);
        uint256 intermediateAmount = _swapThroughValidatedPool(
            cakeAnchorPool, intermediateValidation, amountIn, intermediateValidation.amountOutMin
        );

        RewardSwapValidation memory targetValidation =
            _validateRewardSwap(targetAnchorPool, anchorToken, targetToken, intermediateAmount);
        uint256 routeAmountOutMin = _combinedRouteAmountOutMin(intermediateValidation, targetValidation);
        uint256 targetAmountOutMin =
            targetValidation.amountOutMin > routeAmountOutMin ? targetValidation.amountOutMin : routeAmountOutMin;

        amountOut = _swapThroughValidatedPool(targetAnchorPool, targetValidation, intermediateAmount, targetAmountOutMin);
        return (amountIn, amountOut);
    }

    /// @dev Optional balancing swap between token0 and token1. It always uses the position's own pool.
    function _swapPositionTokens(CompoundState memory state, CompoundParams calldata params)
        internal
        returns (CompoundState memory)
    {
        if (params.pairSwapAmountIn == 0) {
            return state;
        }

        if (params.pairSwap0For1) {
            if (params.pairSwapAmountIn > state.amount0) {
                revert SwapAmountTooLarge();
            }
        } else if (params.pairSwapAmountIn > state.amount1) {
            revert SwapAmountTooLarge();
        }

        int24 currentTick;
        uint160 sqrtPriceX96;
        (sqrtPriceX96, currentTick) = _getPoolSlot0(state.positionPool);
        uint256 amountOutMin = _validateSwap(
            params.pairSwap0For1,
            params.pairSwapAmountIn,
            state.positionPool,
            currentTick,
            sqrtPriceX96,
            TWAPSeconds,
            maxTWAPTickDifference,
            REWARD_MAX_PRICE_DIFFERENCE_X64
        );
        if (params.pairSwapAmountOutMin > amountOutMin) {
            amountOutMin = params.pairSwapAmountOutMin;
        }

        (uint256 amountInDelta, uint256 amountOutDelta) = _poolSwap(
            PoolSwapParams({
                pool: state.positionPool,
                token0: IERC20(state.token0),
                token1: IERC20(state.token1),
                fee: state.positionPool.fee(),
                swap0For1: params.pairSwap0For1,
                amountIn: params.pairSwapAmountIn,
                amountOutMin: amountOutMin
            })
        );

        if (params.pairSwap0For1) {
            state.amount0 = state.amount0 - amountInDelta;
            state.amount1 = state.amount1 + amountOutDelta;
        } else {
            state.amount0 = state.amount0 + amountOutDelta;
            state.amount1 = state.amount1 - amountInDelta;
        }

        return state;
    }

    /// @dev Executes a pool swap only after its direction and min-out were validated.
    function _swapThroughValidatedPool(
        IUniswapV3Pool pool,
        RewardSwapValidation memory validation,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) {
            return 0;
        }

        (, amountOut) = _poolSwap(
            PoolSwapParams({
                pool: pool,
                token0: IERC20(validation.poolToken0),
                token1: IERC20(validation.poolToken1),
                fee: pool.fee(),
                swap0For1: validation.swap0For1,
                amountIn: amountIn,
                amountOutMin: amountOutMin
            })
        );
    }

    /// @dev Validates pool membership, canonical address, direction, and spot/TWAP min-out for a reward swap.
    function _validateRewardSwap(IUniswapV3Pool pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (RewardSwapValidation memory validation)
    {
        if (address(pool) == address(0)) {
            revert NotConfigured();
        }

        validation.poolToken0 = pool.token0();
        validation.poolToken1 = pool.token1();
        _validateCanonicalPool(pool, validation.poolToken0, validation.poolToken1);

        if (validation.poolToken0 == tokenIn && validation.poolToken1 == tokenOut) {
            validation.swap0For1 = true;
        } else if (validation.poolToken0 == tokenOut && validation.poolToken1 == tokenIn) {
            validation.swap0For1 = false;
        } else {
            revert InvalidPool();
        }

        int24 currentTick;
        (validation.sqrtPriceX96, currentTick) = _getPoolSlot0(pool);
        validation.spotAmountOut = _quoteRewardSwapAmountOut(validation.swap0For1, amountIn, validation.sqrtPriceX96);
        validation.amountOutMin = _validateSwap(
            validation.swap0For1,
            amountIn,
            pool,
            currentTick,
            validation.sqrtPriceX96,
            TWAPSeconds,
            maxTWAPTickDifference,
            REWARD_MAX_PRICE_DIFFERENCE_X64
        );
    }

    /// @dev Computes an additional end-to-end route bound for CAKE -> anchor -> target swaps.
    function _combinedRouteAmountOutMin(
        RewardSwapValidation memory intermediateValidation,
        RewardSwapValidation memory targetValidation
    ) internal pure returns (uint256 amountOutMin) {
        uint256 routeSpotAmountOut = _quoteRewardSwapAmountOut(
            targetValidation.swap0For1, intermediateValidation.spotAmountOut, targetValidation.sqrtPriceX96
        );
        amountOutMin = FullMath.mulDiv(routeSpotAmountOut, Q64 - REWARD_MAX_PRICE_DIFFERENCE_X64, Q64);
    }

    /// @dev Spot quote helper used only for min-out calculation; actual output is enforced by pool swap.
    function _quoteRewardSwapAmountOut(bool swap0For1, uint256 amountIn, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) {
            return 0;
        }

        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (swap0For1) {
            return FullMath.mulDiv(amountIn, priceX96, Q96);
        }
        return FullMath.mulDiv(amountIn, Q96, priceX96);
    }

    /// @dev Adds liquidity through MasterChef so the NFT stays staked. Protocol reward is retained in-contract.
    function _addLiquidity(CompoundState memory state, CompoundParams calldata params)
        internal
        returns (CompoundState memory)
    {
        uint256 rewardX64 = totalRewardX64;
        uint256 maxAddAmount0 = state.amount0 * Q64 / (rewardX64 + Q64);
        uint256 maxAddAmount1 = state.amount1 * Q64 / (rewardX64 + Q64);

        if (maxAddAmount0 != 0) {
            IERC20(state.token0).safeIncreaseAllowance(address(masterChef), maxAddAmount0);
        }
        if (maxAddAmount1 != 0) {
            IERC20(state.token1).safeIncreaseAllowance(address(masterChef), maxAddAmount1);
        }

        if (maxAddAmount0 != 0 || maxAddAmount1 != 0) {
            (, state.amountAdded0, state.amountAdded1) = masterChef.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    params.tokenId,
                    maxAddAmount0,
                    maxAddAmount1,
                    params.amount0Min,
                    params.amount1Min,
                    params.deadline
                )
            );
            state.rewardAmount0 = state.amountAdded0 * rewardX64 / Q64;
            state.rewardAmount1 = state.amountAdded1 * rewardX64 / Q64;
        }

        if (maxAddAmount0 != 0) {
            IERC20(state.token0).safeApprove(address(masterChef), 0);
        }
        if (maxAddAmount1 != 0) {
            IERC20(state.token1).safeApprove(address(masterChef), 0);
        }

        return state;
    }

    /// @dev Sends only balances above protected protocol balances plus newly accrued protocol reward.
    function _sendLeftovers(uint256 tokenId, CompoundState memory state) internal {
        _sendExcessBalance(tokenId, state.token0, state.owner, state.balance0Before + state.rewardAmount0);
        if (state.token1 != state.token0) {
            _sendExcessBalance(tokenId, state.token1, state.owner, state.balance1Before + state.rewardAmount1);
        }
        if (address(cakeToken) != state.token0 && address(cakeToken) != state.token1) {
            _sendExcessBalance(tokenId, address(cakeToken), state.owner, state.cakeBalanceBefore);
        }
    }

    /// @dev Transfers balance above protectedBalance and reverts if protectedBalance was consumed.
    function _sendExcessBalance(uint256 tokenId, address token, address owner, uint256 protectedBalance) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < protectedBalance) {
            revert InsufficientLiquidity();
        }

        uint256 amount = balance - protectedBalance;
        if (amount != 0) {
            IERC20(token).safeTransfer(owner, amount);
            emit LeftoverSent(tokenId, token, owner, amount);
        }
    }

    /// @dev Sends only balance growth since balanceBefore; used for transform cleanup.
    function _sendBalanceIncrease(uint256 tokenId, address token, address owner, uint256 balanceBefore) internal {
        uint256 amount = _balanceIncrease(token, balanceBefore);
        if (amount != 0) {
            IERC20(token).safeTransfer(owner, amount);
            emit LeftoverSent(tokenId, token, owner, amount);
        }
    }

    /// @dev Returns a positive balance delta and reverts on any decrease.
    function _balanceIncrease(address token, uint256 balanceBefore) internal view returns (uint256 amount) {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore) {
            revert InsufficientLiquidity();
        }
        amount = balanceAfter - balanceBefore;
    }

    /// @dev After transform, sweep only original token0/token1/CAKE deltas. Other tokens must be handled by transformer.
    function _sweepOriginalTransformTokens(
        uint256 tokenId,
        address owner,
        address token0,
        address token1,
        uint256 balance0Before,
        uint256 balance1Before,
        uint256 cakeBalanceBefore
    ) internal {
        _sendBalanceIncrease(tokenId, token0, owner, balance0Before);
        if (token1 != token0) {
            _sendBalanceIncrease(tokenId, token1, owner, balance1Before);
        }
        if (address(cakeToken) != token0 && address(cakeToken) != token1) {
            _sendBalanceIncrease(tokenId, address(cakeToken), owner, cakeBalanceBefore);
        }
    }

    /// @dev Safe custody probe for NFTs that may be staked in MasterChef, local, burned, or otherwise unavailable.
    function _nftOwnerOrZero(uint256 tokenId) internal view returns (address nftOwner) {
        try nonfungiblePositionManager.ownerOf(tokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            nftOwner = address(0);
        }
    }

    /// @notice ERC721 receiver that stakes new deposits and transform-created NFTs.
    /// @dev Outside transform, direct safeTransferFrom deposits are assigned to `from` unless calldata encodes a
    ///      recipient. During transform, only the original token may arrive from MasterChef; any transformer-sent NFT
    ///      is assigned to the current owner and staked immediately.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }

        uint256 currentTransformedTokenId = transformedTokenId;
        if (currentTransformedTokenId != 0) {
            if (from == address(masterChef)) {
                if (tokenId != currentTransformedTokenId || positionOwners[tokenId] == address(0)) {
                    revert Unauthorized();
                }
            } else {
                address transformOwner = positionOwners[currentTransformedTokenId];
                address existingOwner = positionOwners[tokenId];
                if (transformOwner == address(0) || (existingOwner != address(0) && existingOwner != transformOwner)) {
                    revert Unauthorized();
                }

                if (existingOwner == address(0)) {
                    _addPositionToOwner(transformOwner, tokenId);
                }
                _stakeFromVault(tokenId);
                emit PositionRestaked(tokenId, transformOwner, address(masterChef));
            }
            return IERC721Receiver.onERC721Received.selector;
        }

        if (positionOwners[tokenId] != address(0) || from == address(0) || from == address(masterChef)) {
            revert Unauthorized();
        }

        address owner = from;
        if (data.length != 0) {
            owner = abi.decode(data, (address));
        }

        _addPositionToOwner(owner, tokenId);
        _stakeFromVault(tokenId);
        emit PositionStaked(tokenId, owner, address(masterChef));
        return IERC721Receiver.onERC721Received.selector;
    }
}
