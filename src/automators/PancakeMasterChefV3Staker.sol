// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../interfaces/pancake/IPancakeMasterChefV3.sol";
import "../interfaces/pancake/IPancakeMasterChefV3Staker.sol";
import "../interfaces/pancake/IPancakeV3SwapCallback.sol";
import "../utils/Constants.sol";

/// @notice PancakeSwap V3 MasterChef custody contract for staked NFT positions.
/// @dev MasterChef records this contract as the position user. Logical ownership is tracked in positionOwners.
contract PancakeMasterChefV3Staker is
    Ownable2Step,
    Multicall,
    IERC721Receiver,
    IPancakeV3SwapCallback,
    ReentrancyGuard,
    Constants,
    IPancakeMasterChefV3Staker
{
    using SafeERC20 for IERC20;

    uint64 public constant MAX_REWARD_X64 = uint64(Q64 / 50); // 2%
    uint64 public constant REWARD_MAX_PRICE_DIFFERENCE_X64 = uint64(Q64 / 50); // 2%
    uint32 private constant REWARD_TWAP_SECONDS = 60;
    uint16 private constant REWARD_MAX_TWAP_TICK_DIFFERENCE = 200;

    IERC20 public immutable cakeToken;
    IPancakeMasterChefV3 public immutable masterChef;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    address public immutable factory;

    /// @notice Active original token id during a transform call.
    /// @dev Existing automators validate this value to confirm they are executing inside the staker.
    uint256 public override transformedTokenId;

    /// @notice Protocol fee receiver authority for staker-held reward-compound fees.
    address public withdrawer;
    /// @notice Protocol reward rate in Q64, charged on CAKE amounts successfully added as liquidity.
    uint64 public totalRewardX64 = MAX_REWARD_X64;

    /// @notice Logical owner of each NFT managed by this staker.
    mapping(uint256 => address) public positionOwners;
    /// @notice Contracts allowed to transform positions or automate staker reward actions.
    mapping(address => bool) public transformerAllowList;
    /// @notice Owner approvals for automators to call transform or reward actions on a position.
    mapping(address => mapping(uint256 => mapping(address => bool))) public transformApprovals;
    /// @notice Direct CAKE/base-token pools used by reward compounding and reward conversion routes.
    mapping(address => address) public rewardBasePools;
    /// @notice Per-position harvest payout token. Defaults to CAKE.
    mapping(uint256 => RewardToken) public harvestTokens;

    uint256 private activeFinalTokenId;
    address private activeTransformer;

    struct RewardSwapValidation {
        address poolToken0;
        address poolToken1;
        bool swap0For1;
        uint160 sqrtPriceX96;
        uint256 amountOutMin;
        uint256 spotAmountOut;
    }

    struct RewardCompoundState {
        address token0;
        address token1;
        IUniswapV3Pool positionPool;
        uint256 balance0Before;
        uint256 balance1Before;
        uint256 cakeBalanceBefore;
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 rewardAmount0;
        uint256 rewardAmount1;
    }

    struct TransformState {
        address owner;
        address token0;
        address token1;
        uint256 balance0Before;
        uint256 balance1Before;
        uint256 cakeBalanceBefore;
        uint256 cakeAmount;
        uint256 newTokenId;
    }

    struct RewardPoolSwapParams {
        IUniswapV3Pool pool;
        IERC20 token0;
        IERC20 token1;
        bool swap0For1;
        uint256 amountIn;
        uint256 amountOutMin;
    }

    error ZeroAddress();

    event SetTransformer(address indexed transformer, bool active);
    event ApprovedTransform(uint256 indexed tokenId, address indexed owner, address indexed target, bool active);
    event PositionStaked(uint256 indexed tokenId, address indexed owner, address indexed masterChef);
    event PositionRestaked(uint256 indexed tokenId, address indexed owner, address indexed masterChef);
    event PositionUnstaked(
        uint256 indexed tokenId, address indexed owner, address indexed recipient, uint256 cakeAmount
    );
    event RewardsClaimed(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed recipient,
        address rewardToken,
        uint256 cakeAmount,
        uint256 rewardAmount
    );
    event RewardsCompounded(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 cakeAmount,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1
    );
    event TransformExecuted(
        uint256 indexed tokenId,
        uint256 indexed finalTokenId,
        address indexed owner,
        address transformer,
        uint256 cakeAmount,
        bool rewardCompound
    );
    event LeftoverSent(uint256 indexed tokenId, address indexed token, address indexed to, uint256 amount);
    event RewardBasePoolSet(address indexed baseToken, address indexed pool);
    event HarvestTokenSet(uint256 indexed tokenId, RewardToken rewardToken);
    event RewardUpdated(address account, uint64 totalRewardX64);
    event WithdrawerChanged(address newWithdrawer);

    constructor(INonfungiblePositionManager npm, IPancakeMasterChefV3 _masterChef, IERC20 _cakeToken) {
        if (address(npm) == address(0) || address(_masterChef) == address(0) || address(_cakeToken) == address(0)) {
            revert InvalidConfig();
        }
        if (_masterChef.CAKE() != address(_cakeToken) || _masterChef.nonfungiblePositionManager() != address(npm)) {
            revert InvalidConfig();
        }

        nonfungiblePositionManager = npm;
        masterChef = _masterChef;
        cakeToken = _cakeToken;
        factory = npm.factory();
        _setWithdrawer(msg.sender);
    }

    /// @notice Returns the logical owner recorded by this staker.
    function ownerOf(uint256 tokenId) external view override returns (address owner) {
        owner = positionOwners[tokenId];
    }

    /// @notice Returns the current ERC-721 custodian, or zero if the NFT no longer exists.
    function custodyOf(uint256 tokenId) external view override returns (address nftOwner) {
        nftOwner = _nftOwnerOrZero(tokenId);
    }

    /// @notice Returns true if the staker has logical ownership accounting for tokenId.
    function isManaged(uint256 tokenId) external view override returns (bool managed) {
        managed = positionOwners[tokenId] != address(0);
    }

    /// @notice Returns true if the managed NFT is currently held by MasterChefV3.
    function isStaked(uint256 tokenId) external view override returns (bool staked) {
        staked = positionOwners[tokenId] != address(0) && _nftOwnerOrZero(tokenId) == address(masterChef);
    }

    /// @notice Adds or removes a transformer accepted by this staker.
    function setTransformer(address transformer, bool active) external onlyOwner {
        if (
            transformer == address(0) || transformer == address(this) || transformer == address(masterChef)
                || transformer == address(nonfungiblePositionManager) || transformer == address(cakeToken)
        ) {
            revert InvalidConfig();
        }

        transformerAllowList[transformer] = active;
        emit SetTransformer(transformer, active);
    }

    /// @notice Sets the withdrawer for protocol balances held by the staker.
    function setWithdrawer(address _withdrawer) external onlyOwner {
        _setWithdrawer(_withdrawer);
    }

    /// @notice Lowers protocol reward kept from reward-compounded amounts added as liquidity.
    function setReward(uint64 _totalRewardX64) external onlyOwner {
        if (_totalRewardX64 > totalRewardX64) {
            revert InvalidConfig();
        }
        totalRewardX64 = _totalRewardX64;
        emit RewardUpdated(msg.sender, _totalRewardX64);
    }

    /// @notice Adds, updates, or removes a direct CAKE/base-token pool for reward routes.
    function setRewardBasePool(address baseToken, address pool) external onlyOwner {
        if (baseToken == address(0) || baseToken == address(cakeToken)) {
            revert InvalidConfig();
        }

        if (pool == address(0)) {
            delete rewardBasePools[baseToken];
            emit RewardBasePoolSet(baseToken, address(0));
            return;
        }

        IUniswapV3Pool rewardPool = IUniswapV3Pool(pool);
        address token0 = rewardPool.token0();
        address token1 = rewardPool.token1();
        if (!(token0 == address(cakeToken) && token1 == baseToken || token0 == baseToken
                    && token1 == address(cakeToken))) {
            revert InvalidPool();
        }

        _validateCanonicalPool(rewardPool, token0, token1);
        rewardBasePools[baseToken] = pool;
        emit RewardBasePoolSet(baseToken, pool);
    }

    /// @notice Allows an automator to transform or compound rewards for a specific position.
    function approveTransform(uint256 tokenId, address target, bool active) external override {
        if (positionOwners[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        transformApprovals[msg.sender][tokenId][target] = active;
        emit ApprovedTransform(tokenId, msg.sender, target, active);
    }

    /// @notice Sets the token used by claimRewards for this position.
    function setHarvestToken(uint256 tokenId, RewardToken rewardToken) external override {
        _requireManagedApprovedCaller(tokenId);
        harvestTokens[tokenId] = rewardToken;
        emit HarvestTokenSet(tokenId, rewardToken);
    }

    /// @notice Withdraws token balances accumulated as reward-compound protocol fees.
    function withdrawBalances(address[] calldata tokens, address to) external nonReentrant {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }

        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = IERC20(tokens[i]);
            uint256 balance = token.balanceOf(address(this));
            if (balance != 0) {
                token.safeTransfer(to, balance);
            }
        }
    }

    /// @notice Withdraws ETH held by the staker.
    function withdrawETH(address to) external nonReentrant {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 balance = address(this).balance;
        if (balance != 0) {
            (bool sent,) = to.call{value: balance}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        }
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
    /// @dev Non-empty local positions are restaked; only empty local residual positions can be transferred out.
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
            delete positionOwners[tokenId];
            delete harvestTokens[tokenId];
            cakeAmount = masterChef.withdraw(tokenId, recipient);
            emit PositionUnstaked(tokenId, owner, recipient, cakeAmount);
            return cakeAmount;
        }
        if (nftOwner != address(this)) {
            revert NotConfigured();
        }
        if (_positionLiquidity(tokenId) != 0) {
            _stakeFromStaker(tokenId);
            emit PositionRestaked(tokenId, owner, address(masterChef));
            return 0;
        }

        delete positionOwners[tokenId];
        delete harvestTokens[tokenId];
        nonfungiblePositionManager.safeTransferFrom(address(this), recipient, tokenId);
        emit PositionUnstaked(tokenId, owner, recipient, cakeAmount);
    }

    /// @notice Harvests rewards for a staked position and pays the owner's configured reward token.
    function claimRewards(uint256 tokenId, address recipient)
        external
        override
        nonReentrant
        returns (uint256 rewardAmount)
    {
        address owner = _requireStakedApprovedCaller(tokenId);
        if (recipient == address(0)) {
            recipient = owner;
        }

        (address token0, address token1,, IUniswapV3Pool positionPool) = _positionPoolInfo(tokenId);
        address targetToken = _harvestTokenAddress(harvestTokens[tokenId], token0, token1);
        address otherToken = targetToken == token0 ? token1 : token0;
        uint256 targetBalanceBefore = IERC20(targetToken).balanceOf(address(this));
        uint256 cakeBalanceBefore = cakeToken.balanceOf(address(this));

        uint256 cakeAmount = masterChef.harvest(tokenId, address(this));
        if (cakeAmount != 0 && targetToken != address(cakeToken)) {
            _swapCakeToTarget(positionPool, targetToken, otherToken, cakeAmount);
            _sendExcessBalance(tokenId, address(cakeToken), owner, cakeBalanceBefore);
        }

        rewardAmount = _sendExcessBalance(tokenId, targetToken, recipient, targetBalanceBefore);
        emit RewardsClaimed(tokenId, owner, recipient, targetToken, cakeAmount, rewardAmount);
    }

    /// @notice Harvests CAKE rewards, swaps them into the position tokens, and increases staked liquidity.
    function compoundRewards(uint256 tokenId, RewardCompoundParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1)
    {
        address owner = _requireStakedApprovedCaller(tokenId);
        (cakeAmount, amountAdded0, amountAdded1) = _compoundRewards(tokenId, owner, params);
    }

    /// @notice Temporarily withdraws a staked NFT, calls a transformer, then restakes non-empty results.
    /// @dev CAKE harvested by MasterChef withdrawal is sent to the logical owner before the transformer runs.
    function transform(uint256 tokenId, address transformer, bytes calldata data)
        external
        override
        nonReentrant
        returns (uint256 newTokenId)
    {
        RewardCompoundParams memory emptyParams;
        newTokenId = _transform(tokenId, transformer, data, false, emptyParams);
    }

    /// @notice Compounds harvested CAKE in the staker, then runs the normal transform path.
    function transformWithRewardCompound(
        uint256 tokenId,
        address transformer,
        bytes calldata data,
        RewardCompoundParams calldata params
    ) external override nonReentrant returns (uint256 newTokenId) {
        newTokenId = _transform(tokenId, transformer, data, true, params);
    }

    function _transform(
        uint256 tokenId,
        address transformer,
        bytes calldata data,
        bool rewardCompound,
        RewardCompoundParams memory rewardParams
    ) internal returns (uint256 newTokenId) {
        if (tokenId == 0 || !transformerAllowList[transformer]) {
            revert TransformNotAllowed();
        }
        if (transformedTokenId != 0) {
            revert Reentrancy();
        }

        TransformState memory state;
        state.owner = _requireStakedPosition(tokenId);
        if (msg.sender != state.owner) {
            if (msg.sender != transformer || !transformApprovals[state.owner][tokenId][msg.sender]) {
                revert Unauthorized();
            }
        }

        if (rewardCompound) {
            _compoundRewards(tokenId, state.owner, rewardParams);
        }

        transformedTokenId = tokenId;
        activeFinalTokenId = tokenId;
        activeTransformer = transformer;

        (state.token0, state.token1) = _positionTokens(tokenId);
        state.balance0Before = IERC20(state.token0).balanceOf(address(this));
        state.balance1Before = IERC20(state.token1).balanceOf(address(this));
        state.cakeBalanceBefore = cakeToken.balanceOf(address(this));

        state.cakeAmount = _withdrawToSelf(tokenId);
        if (state.cakeAmount != 0) {
            cakeToken.safeTransfer(state.owner, state.cakeAmount);
        }

        nonfungiblePositionManager.approve(transformer, tokenId);
        _callTransformer(transformer, data);

        state.newTokenId = activeFinalTokenId == 0 ? tokenId : activeFinalTokenId;
        if (positionOwners[state.newTokenId] != state.owner) {
            revert Unauthorized();
        }
        newTokenId = state.newTokenId;

        transformedTokenId = 0;
        activeFinalTokenId = 0;
        activeTransformer = address(0);

        _finalizeTransformPosition(tokenId);
        _sweepTransformTokenIncreases(
            tokenId,
            state.owner,
            state.token0,
            state.token1,
            state.balance0Before,
            state.balance1Before,
            state.cakeBalanceBefore
        );

        emit TransformExecuted(tokenId, newTokenId, state.owner, transformer, state.cakeAmount, rewardCompound);
    }

    function _compoundRewards(uint256 tokenId, address owner, RewardCompoundParams memory params)
        internal
        returns (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1)
    {
        if (params.cakeSplitBps > 10_000) {
            revert InvalidConfig();
        }

        RewardCompoundState memory state;
        (state.token0, state.token1,, state.positionPool) = _positionPoolInfo(tokenId);
        state.balance0Before = IERC20(state.token0).balanceOf(address(this));
        state.balance1Before = IERC20(state.token1).balanceOf(address(this));
        state.cakeBalanceBefore = cakeToken.balanceOf(address(this));

        cakeAmount = masterChef.harvest(tokenId, address(this));
        if (cakeAmount < params.minCakeReward) {
            revert NotEnoughReward();
        }
        if (cakeAmount == 0) {
            emit RewardsCompounded(tokenId, owner, 0, 0, 0, 0, 0);
            return (0, 0, 0);
        }

        uint256 requestedCake0 = cakeAmount * params.cakeSplitBps / 10_000;
        uint256 requestedCake1 = cakeAmount - requestedCake0;
        state.amount0 = _swapCakeToTarget(state.positionPool, state.token0, state.token1, requestedCake0);
        state.amount1 = _swapCakeToTarget(state.positionPool, state.token1, state.token0, requestedCake1);

        uint256 rewardX64 = totalRewardX64;
        state.maxAddAmount0 = state.amount0 * Q64 / (rewardX64 + Q64);
        state.maxAddAmount1 = state.amount1 * Q64 / (rewardX64 + Q64);

        if (state.maxAddAmount0 != 0) {
            IERC20(state.token0).safeIncreaseAllowance(address(masterChef), state.maxAddAmount0);
        }
        if (state.maxAddAmount1 != 0) {
            IERC20(state.token1).safeIncreaseAllowance(address(masterChef), state.maxAddAmount1);
        }

        uint128 liquidityAdded;
        if (state.maxAddAmount0 != 0 || state.maxAddAmount1 != 0) {
            (liquidityAdded, amountAdded0, amountAdded1) = masterChef.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId,
                    state.maxAddAmount0,
                    state.maxAddAmount1,
                    params.amount0Min,
                    params.amount1Min,
                    params.deadline
                )
            );
            if (liquidityAdded == 0 && (amountAdded0 != 0 || amountAdded1 != 0)) {
                revert InvalidConfig();
            }
        }

        if (state.maxAddAmount0 != 0) {
            IERC20(state.token0).safeApprove(address(masterChef), 0);
        }
        if (state.maxAddAmount1 != 0) {
            IERC20(state.token1).safeApprove(address(masterChef), 0);
        }

        state.rewardAmount0 = amountAdded0 * rewardX64 / Q64;
        state.rewardAmount1 = amountAdded1 * rewardX64 / Q64;
        _sendExcessBalance(tokenId, state.token0, owner, state.balance0Before + state.rewardAmount0);
        if (state.token1 != state.token0) {
            _sendExcessBalance(tokenId, state.token1, owner, state.balance1Before + state.rewardAmount1);
        }
        if (address(cakeToken) != state.token0 && address(cakeToken) != state.token1) {
            _sendExcessBalance(tokenId, address(cakeToken), owner, state.cakeBalanceBefore);
        }

        emit RewardsCompounded(
            tokenId, owner, cakeAmount, amountAdded0, amountAdded1, state.rewardAmount0, state.rewardAmount1
        );
    }

    function _swapCakeToTarget(IUniswapV3Pool positionPool, address targetToken, address otherToken, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) {
            return 0;
        }
        if (targetToken == address(cakeToken)) {
            return amountIn;
        }

        address directPool = rewardBasePools[targetToken];
        if (directPool != address(0)) {
            return _swapThroughPool(IUniswapV3Pool(directPool), address(cakeToken), targetToken, amountIn);
        }

        if (otherToken == address(cakeToken)) {
            return _swapThroughPool(positionPool, address(cakeToken), targetToken, amountIn);
        }

        address intermediatePool = rewardBasePools[otherToken];
        if (intermediatePool == address(0)) {
            revert NotConfigured();
        }

        RewardSwapValidation memory intermediateValidation =
            _validateRewardSwap(IUniswapV3Pool(intermediatePool), address(cakeToken), otherToken, amountIn);
        uint256 intermediateAmount = _swapThroughValidatedPool(
            IUniswapV3Pool(intermediatePool), intermediateValidation, amountIn, intermediateValidation.amountOutMin
        );

        RewardSwapValidation memory targetValidation =
            _validateRewardSwap(positionPool, otherToken, targetToken, intermediateAmount);
        uint256 routeAmountOutMin = _combinedRouteAmountOutMin(intermediateValidation, targetValidation);
        uint256 targetAmountOutMin =
            targetValidation.amountOutMin > routeAmountOutMin ? targetValidation.amountOutMin : routeAmountOutMin;

        return _swapThroughValidatedPool(positionPool, targetValidation, intermediateAmount, targetAmountOutMin);
    }

    function _swapThroughPool(IUniswapV3Pool pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        RewardSwapValidation memory validation = _validateRewardSwap(pool, tokenIn, tokenOut, amountIn);
        amountOut = _swapThroughValidatedPool(pool, validation, amountIn, validation.amountOutMin);
    }

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
            RewardPoolSwapParams({
                pool: pool,
                token0: IERC20(validation.poolToken0),
                token1: IERC20(validation.poolToken1),
                swap0For1: validation.swap0For1,
                amountIn: amountIn,
                amountOutMin: amountOutMin
            })
        );
    }

    function _poolSwap(RewardPoolSwapParams memory params)
        internal
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        if (params.amountIn == 0) {
            return (0, 0);
        }

        (int256 amount0Delta, int256 amount1Delta) = params.pool
            .swap(
                address(this),
                params.swap0For1,
                SafeCast.toInt256(params.amountIn),
                params.swap0For1 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                abi.encode(
                    params.swap0For1 ? params.token0 : params.token1,
                    params.swap0For1 ? params.token1 : params.token0,
                    params.pool.fee()
                )
            );
        amountInDelta = params.swap0For1 ? SafeCast.toUint256(amount0Delta) : SafeCast.toUint256(amount1Delta);
        amountOutDelta = params.swap0For1 ? SafeCast.toUint256(-amount1Delta) : SafeCast.toUint256(-amount0Delta);

        if (amountOutDelta < params.amountOutMin) {
            revert SlippageError();
        }
    }

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
            REWARD_TWAP_SECONDS,
            REWARD_MAX_TWAP_TICK_DIFFERENCE,
            REWARD_MAX_PRICE_DIFFERENCE_X64
        );
    }

    function _validateSwap(
        bool swap0For1,
        uint256 amountIn,
        IUniswapV3Pool pool,
        int24 currentTick,
        uint160 sqrtPriceX96,
        uint32 twapPeriod,
        uint16 maxTickDifference,
        uint64 maxPriceDifferenceX64
    ) internal view returns (uint256 amountOutMin) {
        if (!_hasMaxTWAPTickDifference(pool, twapPeriod, currentTick, maxTickDifference)) {
            revert TWAPCheckFailed();
        }

        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        uint256 spotAmountOut;
        if (swap0For1) {
            spotAmountOut = FullMath.mulDiv(amountIn, priceX96, Q96);
        } else {
            spotAmountOut = FullMath.mulDiv(amountIn, Q96, priceX96);
        }
        amountOutMin = FullMath.mulDiv(spotAmountOut, Q64 - maxPriceDifferenceX64, Q64);
    }

    function _hasMaxTWAPTickDifference(IUniswapV3Pool pool, uint32 twapPeriod, int24 currentTick, uint16 maxDifference)
        internal
        view
        returns (bool)
    {
        (int24 twapTick, bool twapOk) = _getTWAPTick(pool, twapPeriod);
        if (!twapOk) {
            return false;
        }
        int256 difference = twapTick - currentTick;
        return difference >= -int16(maxDifference) && difference <= int16(maxDifference);
    }

    function _getTWAPTick(IUniswapV3Pool pool, uint32 twapSeconds) internal view returns (int24, bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = twapSeconds;

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[0] - tickCumulatives[1];
            int24 tick = int24(delta / int56(uint56(twapSeconds)));
            if (delta < 0 && delta % int32(twapSeconds) != 0) tick--;
            return (tick, true);
        } catch {
            return (0, false);
        }
    }

    function _combinedRouteAmountOutMin(
        RewardSwapValidation memory intermediateValidation,
        RewardSwapValidation memory targetValidation
    ) internal pure returns (uint256 amountOutMin) {
        uint256 routeSpotAmountOut = _quoteRewardSwapAmountOut(
            targetValidation.swap0For1, intermediateValidation.spotAmountOut, targetValidation.sqrtPriceX96
        );
        amountOutMin = FullMath.mulDiv(routeSpotAmountOut, Q64 - REWARD_MAX_PRICE_DIFFERENCE_X64, Q64);
    }

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

    function _callTransformer(address transformer, bytes calldata data) internal {
        (bool success, bytes memory revertData) = transformer.call(data);
        if (success) {
            return;
        }
        if (revertData.length == 0) {
            revert TransformFailed();
        }
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    function _setWithdrawer(address _withdrawer) internal {
        if (_withdrawer == address(0)) {
            revert ZeroAddress();
        }
        withdrawer = _withdrawer;
        emit WithdrawerChanged(_withdrawer);
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

    function _requireManagedApprovedCaller(uint256 tokenId) internal view returns (address owner) {
        owner = positionOwners[tokenId];
        if (owner == address(0)) {
            revert NotConfigured();
        }
        if (msg.sender == owner) {
            return owner;
        }
        if (!transformerAllowList[msg.sender] || !transformApprovals[owner][tokenId][msg.sender]) {
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

    function _requireStakedApprovedCaller(uint256 tokenId) internal view returns (address owner) {
        owner = _requireStakedPosition(tokenId);
        if (msg.sender == owner) {
            return owner;
        }
        if (!transformerAllowList[msg.sender] || !transformApprovals[owner][tokenId][msg.sender]) {
            revert Unauthorized();
        }
    }

    function _positionTokens(uint256 tokenId) internal view returns (address token0, address token1) {
        (,, token0, token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
    }

    function _positionPoolInfo(uint256 tokenId)
        internal
        view
        returns (address token0, address token1, uint24 fee, IUniswapV3Pool pool)
    {
        (,, token0, token1, fee,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        if (token0 == address(0) || token1 == address(0) || token0 == token1) {
            revert InvalidConfig();
        }
        pool = _getPool(token0, token1, fee);
        if (address(pool) == address(0)) {
            revert InvalidPool();
        }
    }

    function _positionLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
    }

    function _harvestTokenAddress(RewardToken rewardToken, address token0, address token1)
        internal
        view
        returns (address token)
    {
        if (rewardToken == RewardToken.TOKEN0) {
            return token0;
        }
        if (rewardToken == RewardToken.TOKEN1) {
            return token1;
        }
        return address(cakeToken);
    }

    function _stakeFromStaker(uint256 tokenId) internal {
        nonfungiblePositionManager.safeTransferFrom(address(this), address(masterChef), tokenId);
        if (nonfungiblePositionManager.ownerOf(tokenId) != address(masterChef)) {
            revert InvalidConfig();
        }
    }

    function _withdrawToSelf(uint256 tokenId) internal returns (uint256 cakeAmount) {
        cakeAmount = masterChef.withdraw(tokenId, address(this));
    }

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
            _stakeFromStaker(tokenId);
            emit PositionRestaked(tokenId, owner, address(masterChef));
        }
    }

    function _sweepTransformTokenIncreases(
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

    function _sendBalanceIncrease(uint256 tokenId, address token, address owner, uint256 balanceBefore) internal {
        uint256 amount = _balanceIncrease(token, balanceBefore);
        if (amount != 0) {
            IERC20(token).safeTransfer(owner, amount);
            emit LeftoverSent(tokenId, token, owner, amount);
        }
    }

    function _sendExcessBalance(uint256 tokenId, address token, address to, uint256 protectedBalance)
        internal
        returns (uint256 amount)
    {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < protectedBalance) {
            revert InsufficientLiquidity();
        }

        amount = balance - protectedBalance;
        if (amount != 0) {
            IERC20(token).safeTransfer(to, amount);
            emit LeftoverSent(tokenId, token, to, amount);
        }
    }

    function _balanceIncrease(address token, uint256 balanceBefore) internal view returns (uint256 amount) {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore) {
            revert InsufficientLiquidity();
        }
        amount = balanceAfter - balanceBefore;
    }

    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(IUniswapV3Factory(factory).getPool(tokenA, tokenB, fee));
    }

    function _validateCanonicalPool(IUniswapV3Pool pool, address token0, address token1) internal view {
        if (address(pool) == address(0) || address(_getPool(token0, token1, pool.fee())) != address(pool)) {
            revert InvalidPool();
        }
    }

    function _getPoolSlot0(IUniswapV3Pool pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (bool success, bytes memory data) = address(pool).staticcall(abi.encodeWithSelector(pool.slot0.selector));
        if (!success || data.length < 64) {
            revert InvalidPool();
        }

        uint256 sqrtPriceX96Raw;
        int256 tickRaw;
        assembly ("memory-safe") {
            sqrtPriceX96Raw := mload(add(data, 0x20))
            tickRaw := mload(add(data, 0x40))
        }
        sqrtPriceX96 = SafeCast.toUint160(sqrtPriceX96Raw);
        tick = SafeCast.toInt24(tickRaw);
    }

    function _nftOwnerOrZero(uint256 tokenId) internal view returns (address nftOwner) {
        try nonfungiblePositionManager.ownerOf(tokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            nftOwner = address(0);
        }
    }

    /// @notice Pancake v3 pools call this callback during direct reward swaps.
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        require(amount0Delta > 0 || amount1Delta > 0);

        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        if (address(_getPool(tokenIn, tokenOut, fee)) != msg.sender) {
            revert Unauthorized();
        }

        IERC20(tokenIn).safeTransfer(msg.sender, amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta));
    }

    /// @notice Receives Pancake V3 NFTs for deposits, MasterChef withdrawals, and transform-created positions.
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
                activeFinalTokenId = tokenId;
                return IERC721Receiver.onERC721Received.selector;
            }

            address transformOwner = positionOwners[currentTransformedTokenId];
            address existingOwner = positionOwners[tokenId];
            if (transformOwner == address(0) || (existingOwner != address(0) && existingOwner != transformOwner)) {
                revert Unauthorized();
            }

            if (existingOwner == address(0)) {
                positionOwners[tokenId] = transformOwner;
                harvestTokens[tokenId] = harvestTokens[currentTransformedTokenId];
            }
            if (
                tokenId != currentTransformedTokenId && activeTransformer != address(0)
                    && transformApprovals[transformOwner][currentTransformedTokenId][activeTransformer]
            ) {
                transformApprovals[transformOwner][tokenId][activeTransformer] = true;
            }

            activeFinalTokenId = tokenId;
            if (_positionLiquidity(tokenId) != 0) {
                _stakeFromStaker(tokenId);
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
        if (owner == address(0)) {
            revert ZeroAddress();
        }

        positionOwners[tokenId] = owner;
        _stakeFromStaker(tokenId);
        emit PositionStaked(tokenId, owner, address(masterChef));
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
