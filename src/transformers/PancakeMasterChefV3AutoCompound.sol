// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../automators/Automator.sol";
import "../interfaces/pancake/IPancakeMasterChefV3Staker.sol";
import "../transformers/Transformer.sol";

/// @notice PancakeSwap V3 fee and CAKE reward compounding automator.
/// @dev Owner-held NFTs use direct operator execution. MasterChef-staked NFTs execute through the staker transform flow.
contract PancakeMasterChefV3AutoCompound is
    Transformer,
    Automator,
    Multicall,
    ReentrancyGuard,
    IPancakeMasterChefV3RewardTransformer
{
    using SafeERC20 for IERC20;

    /// @notice Maximum protocol reward kept from amounts added back into the position.
    uint64 public constant MAX_REWARD_X64 = uint64(Q64 / 50); // 2%
    /// @notice Maximum tolerated spot/TWAP difference used for CAKE and balancing swaps.
    uint64 public constant REWARD_MAX_PRICE_DIFFERENCE_X64 = uint64(Q64 / 50); // 2%

    IERC20 public immutable cakeToken;

    /// @notice Protocol reward rate in Q64, charged on amounts successfully added as liquidity.
    uint64 public totalRewardX64 = MAX_REWARD_X64;
    /// @notice Anchor token configs used to validate dynamic CAKE reward routes.
    mapping(address => AnchorConfig) public rewardAnchors;
    /// @notice Optional owner-defined execution limits for individual positions.
    mapping(uint256 => CompoundConfig) public compoundConfigs;

    event RewardAnchorSet(address indexed anchorToken, uint256 anchorTokenMinBalance, bool active);
    event RewardUpdated(address account, uint64 totalRewardX64);
    event PositionConfigured(
        uint256 indexed tokenId,
        bool configured,
        uint128 autoCompoundMin0,
        uint128 autoCompoundMin1,
        uint128 minCakeReward,
        uint64 maxRewardX64
    );
    event LeftoverSent(uint256 indexed tokenId, address indexed token, address indexed to, uint256 amount);
    event AutoCompounded(
        address account,
        uint256 indexed tokenId,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1,
        uint256 cakeAmount
    );

    /// @notice Parameters for fee-only or CAKE+fee compounding.
    struct ExecuteParams {
        uint256 tokenId;
        uint256 minCakeReward;
        uint256 cakeSplitBps;
        IUniswapV3Pool token0CakePool;
        IUniswapV3Pool token0AnchorPool;
        IUniswapV3Pool token1CakePool;
        IUniswapV3Pool token1AnchorPool;
        bool pairSwap0For1;
        uint256 pairSwapAmountIn;
        uint256 pairSwapAmountOutMin;
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

    /// @notice Optional per-position limits. Unconfigured positions use only call params and global reward settings.
    struct CompoundConfig {
        bool configured;
        uint128 autoCompoundMin0;
        uint128 autoCompoundMin1;
        uint128 minCakeReward;
        uint64 maxRewardX64;
    }

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
        if (address(_cakeToken) == address(0)) {
            revert InvalidConfig();
        }
        cakeToken = _cakeToken;
    }

    /// @notice Fee-compounds a Pancake-staked position through a configured staker.
    function executeWithPancakeStaker(ExecuteParams calldata params, address staker) external {
        if (!operators[msg.sender] || !pancakeStakers[staker]) {
            revert Unauthorized();
        }
        uint256 finalTokenId = IPancakeMasterChefV3Staker(staker)
            .transform(params.tokenId, address(this), abi.encodeCall(PancakeMasterChefV3AutoCompound.execute, (params)));
        if (finalTokenId != params.tokenId) {
            revert InvalidConfig();
        }
    }

    /// @notice Compounds trading fees and harvested CAKE through a configured staker.
    function executeWithRewardPancakeStaker(ExecuteParams calldata params, address staker) external {
        _executeWithPancakeStakerAndRewardCompound(params, staker);
    }

    /// @notice Explicit alias for CAKE reward compounding through a configured Pancake staker.
    function executeWithPancakeStakerAndRewardCompound(ExecuteParams calldata params, address staker) external {
        _executeWithPancakeStakerAndRewardCompound(params, staker);
    }

    function _executeWithPancakeStakerAndRewardCompound(ExecuteParams calldata params, address staker) internal {
        if (!operators[msg.sender] || !pancakeStakers[staker]) {
            revert Unauthorized();
        }
        uint256 finalTokenId = IPancakeMasterChefV3Staker(staker)
            .transformWithRewardCompound(params.tokenId, address(this), abi.encode(params));
        if (finalTokenId != params.tokenId) {
            revert InvalidConfig();
        }
    }

    /// @notice Fee-compounds an owner-held Pancake V3 NFT or handles a staker transform callback.
    /// @dev For owner-held NFTs, the owner must approve this contract in the Pancake V3 position manager.
    function execute(ExecuteParams calldata params) external nonReentrant {
        address owner;
        if (pancakeStakers[msg.sender]) {
            _validateCaller(nonfungiblePositionManager, params.tokenId);
            owner = IPancakeMasterChefV3Staker(msg.sender).ownerOf(params.tokenId);
        } else {
            if (!operators[msg.sender]) {
                revert Unauthorized();
            }
            owner = nonfungiblePositionManager.ownerOf(params.tokenId);
        }

        _compound(params, owner, 0);
    }

    /// @notice CAKE+fee compound callback used by staker transformWithRewardCompound.
    function executeWithReward(uint256 tokenId, address owner, uint256 cakeAmount, bytes calldata data)
        external
        override
        nonReentrant
    {
        if (!pancakeStakers[msg.sender]) {
            revert Unauthorized();
        }
        _validateCaller(nonfungiblePositionManager, tokenId);

        ExecuteParams memory params = abi.decode(data, (ExecuteParams));
        if (params.tokenId != tokenId || owner == address(0)) {
            revert InvalidConfig();
        }

        _compound(params, owner, cakeAmount);
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

    /// @notice Configures owner-held position limits for direct operator fee compounding.
    function configToken(uint256 tokenId, CompoundConfig calldata config) external {
        _configToken(tokenId, address(0), config);
    }

    /// @notice Configures staker-held position limits for operator fee or CAKE+fee compounding.
    function configToken(uint256 tokenId, address staker, CompoundConfig calldata config) external {
        _configToken(tokenId, staker, config);
    }

    function _configToken(uint256 tokenId, address staker, CompoundConfig calldata config) internal {
        _validateOwner(nonfungiblePositionManager, tokenId, staker);
        if (config.configured && config.maxRewardX64 > MAX_REWARD_X64) {
            revert InvalidConfig();
        }

        compoundConfigs[tokenId] = config;
        emit PositionConfigured(
            tokenId,
            config.configured,
            config.autoCompoundMin0,
            config.autoCompoundMin1,
            config.minCakeReward,
            config.maxRewardX64
        );
    }

    function _compound(ExecuteParams memory params, address owner, uint256 cakeAmount)
        internal
        returns (uint256 amountAdded0, uint256 amountAdded1)
    {
        if (params.cakeSplitBps > 10_000 || owner == address(0)) {
            revert InvalidConfig();
        }

        CompoundState memory state;
        state.owner = owner;
        state.cakeAmount = cakeAmount;
        (state.token0, state.token1,, state.positionPool) = _positionPoolInfo(params.tokenId);

        state.balance0Before = IERC20(state.token0).balanceOf(address(this));
        state.balance1Before = IERC20(state.token1).balanceOf(address(this));
        state.cakeBalanceBefore = cakeToken.balanceOf(address(this));
        _removeTransferredCakeFromProtectedBalances(state);

        CompoundConfig memory config = compoundConfigs[params.tokenId];
        if (config.configured && totalRewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        uint256 minCakeReward = params.minCakeReward;
        if (config.configured && config.minCakeReward > minCakeReward) {
            minCakeReward = config.minCakeReward;
        }
        if (state.cakeAmount < minCakeReward) {
            revert NotEnoughReward();
        }

        (uint256 collected0, uint256 collected1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                params.tokenId, address(this), type(uint128).max, type(uint128).max
            )
        );
        state.amount0 += collected0;
        state.amount1 += collected1;

        if (
            config.configured
                && (collected0 < uint256(config.autoCompoundMin0) || collected1 < uint256(config.autoCompoundMin1))
        ) {
            revert NotEnoughReward();
        }

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
            state.token1,
            state.cakeAmount
        );

        return (state.amountAdded0, state.amountAdded1);
    }

    function _removeTransferredCakeFromProtectedBalances(CompoundState memory state) internal view {
        if (state.cakeAmount == 0) {
            return;
        }
        if (state.cakeBalanceBefore < state.cakeAmount) {
            revert InsufficientLiquidity();
        }
        state.cakeBalanceBefore -= state.cakeAmount;

        if (state.token0 == address(0) || state.token1 == address(0) || state.token0 == state.token1) {
            revert InvalidConfig();
        }
        if (state.token0 == address(cakeToken)) {
            if (state.balance0Before < state.cakeAmount) {
                revert InsufficientLiquidity();
            }
            state.balance0Before -= state.cakeAmount;
        }
        if (state.token1 == address(cakeToken)) {
            if (state.balance1Before < state.cakeAmount) {
                revert InsufficientLiquidity();
            }
            state.balance1Before -= state.cakeAmount;
        }
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

    function _validateCakeAnchorPool(address anchorToken, IUniswapV3Pool cakePool, AnchorConfig memory anchor)
        internal
        view
    {
        if (address(cakePool) == address(0)) {
            revert NotConfigured();
        }

        address token0 = cakePool.token0();
        address token1 = cakePool.token1();
        if (!(token0 == address(cakeToken) && token1 == anchorToken || token0 == anchorToken
                    && token1 == address(cakeToken))) {
            revert InvalidPool();
        }
        _validateCanonicalPool(cakePool, token0, token1);
        if (IERC20(anchorToken).balanceOf(address(cakePool)) < anchor.anchorTokenMinBalance) {
            revert InsufficientLiquidity();
        }
    }

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

    function _validateCanonicalPool(IUniswapV3Pool pool, address token0, address token1) internal view {
        if (address(pool) == address(0) || address(_getPool(token0, token1, pool.fee())) != address(pool)) {
            revert InvalidPool();
        }
    }

    function _swapCakeForPosition(CompoundState memory state, ExecuteParams memory params)
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

    function _swapCakeToTarget(
        address targetToken,
        IUniswapV3Pool cakeAnchorPool,
        IUniswapV3Pool targetAnchorPool,
        uint256 amountIn
    ) internal returns (uint256 spentCake, uint256 amountOut) {
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
            amountOut =
                _swapThroughValidatedPool(cakeAnchorPool, directValidation, amountIn, directValidation.amountOutMin);
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

        amountOut =
            _swapThroughValidatedPool(targetAnchorPool, targetValidation, intermediateAmount, targetAmountOutMin);
        return (amountIn, amountOut);
    }

    function _swapPositionTokens(CompoundState memory state, ExecuteParams memory params)
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

    function _addLiquidity(CompoundState memory state, ExecuteParams memory params)
        internal
        returns (CompoundState memory)
    {
        uint256 rewardX64 = totalRewardX64;
        uint256 maxAddAmount0 = state.amount0 * Q64 / (rewardX64 + Q64);
        uint256 maxAddAmount1 = state.amount1 * Q64 / (rewardX64 + Q64);

        if (maxAddAmount0 != 0) {
            IERC20(state.token0).safeIncreaseAllowance(address(nonfungiblePositionManager), maxAddAmount0);
        }
        if (maxAddAmount1 != 0) {
            IERC20(state.token1).safeIncreaseAllowance(address(nonfungiblePositionManager), maxAddAmount1);
        }

        if (maxAddAmount0 != 0 || maxAddAmount1 != 0) {
            (uint128 liquidityAdded, uint256 amountAdded0, uint256 amountAdded1) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    params.tokenId, maxAddAmount0, maxAddAmount1, params.amount0Min, params.amount1Min, params.deadline
                )
            );
            state.amountAdded0 = amountAdded0;
            state.amountAdded1 = amountAdded1;
            if (liquidityAdded == 0 && (state.amountAdded0 != 0 || state.amountAdded1 != 0)) {
                revert InvalidConfig();
            }
            state.rewardAmount0 = state.amountAdded0 * rewardX64 / Q64;
            state.rewardAmount1 = state.amountAdded1 * rewardX64 / Q64;
        }

        if (maxAddAmount0 != 0) {
            IERC20(state.token0).safeApprove(address(nonfungiblePositionManager), 0);
        }
        if (maxAddAmount1 != 0) {
            IERC20(state.token1).safeApprove(address(nonfungiblePositionManager), 0);
        }

        return state;
    }

    function _sendLeftovers(uint256 tokenId, CompoundState memory state) internal {
        _sendExcessBalance(tokenId, state.token0, state.owner, state.balance0Before + state.rewardAmount0);
        if (state.token1 != state.token0) {
            _sendExcessBalance(tokenId, state.token1, state.owner, state.balance1Before + state.rewardAmount1);
        }
        if (address(cakeToken) != state.token0 && address(cakeToken) != state.token1) {
            _sendExcessBalance(tokenId, address(cakeToken), state.owner, state.cakeBalanceBefore);
        }
    }

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
}
