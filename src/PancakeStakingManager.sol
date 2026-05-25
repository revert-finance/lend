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
import "./interfaces/pancake/IPancakeMasterChefV3.sol";
import "./utils/Swapper.sol";

/// @notice PancakeSwap MasterChefV3 staking helper for vaulted positions.
contract PancakeStakingManager is Ownable2Step, ReentrancyGuard, IERC721Receiver, Swapper, IGaugeManager {
    using SafeERC20 for IERC20;

    uint64 public constant MAX_REWARD_X64 = 368_934_881_474_191_032; // floor(Q64 / 50)
    uint32 private constant REWARD_TWAP_SECONDS = 60;
    uint16 private constant REWARD_MAX_TWAP_TICK_DIFFERENCE = 200;
    uint64 private constant REWARD_MAX_PRICE_DIFFERENCE_X64 = 368_934_881_474_191_032; // floor(Q64 / 50)

    IERC20 public immutable cakeToken;
    IPancakeMasterChefV3 public immutable masterChef;
    IVault public immutable vault;
    address public override withdrawer;
    uint64 public totalRewardX64 = MAX_REWARD_X64; // 2%

    mapping(address => address) public override poolToGauge;
    mapping(uint256 => address) public override tokenIdToGauge;
    mapping(address => address) public override rewardBasePools;

    struct CompoundState {
        address owner;
        address token0;
        address token1;
        IUniswapV3Pool positionPool;
        uint256 cakeAmount;
        uint256 spentCake;
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
        IPancakeMasterChefV3 _masterChef,
        IERC20 _cakeToken,
        IVault _vault,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Swapper(_npm, _universalRouter, _zeroxAllowanceHolder) {
        if (address(_masterChef) == address(0) || address(_cakeToken) == address(0) || address(_vault) == address(0)) {
            revert InvalidConfig();
        }
        if (_masterChef.CAKE() != address(_cakeToken) || _masterChef.nonfungiblePositionManager() != address(_npm)) {
            revert InvalidConfig();
        }

        masterChef = _masterChef;
        cakeToken = _cakeToken;
        vault = _vault;
        withdrawer = msg.sender;

        emit WithdrawerChanged(msg.sender);
    }

    function setGauge(address pool, address gauge) external override onlyOwner {
        if (pool == address(0) || gauge != address(masterChef)) {
            revert InvalidConfig();
        }

        uint256 pid = masterChef.v3PoolAddressPid(pool);
        if (pid == 0) {
            revert InvalidPool();
        }

        (, IUniswapV3Pool v3Pool, address token0, address token1, uint24 fee,,) = masterChef.poolInfo(pid);
        if (address(v3Pool) != pool || address(_getPool(token0, token1, fee)) != pool) {
            revert InvalidPool();
        }

        poolToGauge[pool] = gauge;
        emit GaugeSet(pool, gauge);
    }

    function setRewardBasePool(address baseToken, address pool) external override onlyOwner {
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
        if (address(_getPool(token0, token1, rewardPool.fee())) != pool) {
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

    function withdrawBalances(address[] calldata tokens, address to) external override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        for (; i < count; ++i) {
            IERC20 token = IERC20(tokens[i]);
            uint256 balance = token.balanceOf(address(this));
            if (balance != 0) {
                token.safeTransfer(to, balance);
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

        (,, address token0, address token1, uint24 fee,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        address gauge = poolToGauge[address(pool)];
        if (gauge != address(masterChef)) {
            revert NotConfigured();
        }

        nonfungiblePositionManager.safeTransferFrom(address(vault), address(this), tokenId);
        nonfungiblePositionManager.safeTransferFrom(address(this), address(masterChef), tokenId);
        if (nonfungiblePositionManager.ownerOf(tokenId) != address(masterChef)) {
            revert InvalidConfig();
        }

        tokenIdToGauge[tokenId] = address(masterChef);
        emit PositionStaked(tokenId, owner, address(masterChef));
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

    function claimRewards(uint256 tokenId, address recipient)
        external
        override
        nonReentrant
        returns (uint256 cakeAmount)
    {
        address owner = _requireVaultOrOwner(tokenId);
        _requireStakedGauge(tokenId);

        if (recipient == address(0)) {
            recipient = owner;
        }
        cakeAmount = masterChef.harvest(tokenId, recipient);
        emit RewardsClaimed(tokenId, owner, cakeAmount);
    }

    function compoundRewards(uint256 tokenId, uint256 minReward, uint256 rewardSplitBps, uint256 deadline)
        external
        override
        nonReentrant
        returns (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1)
    {
        address owner = _requireVaultOrOwner(tokenId);
        if (rewardSplitBps > 10_000) {
            revert InvalidConfig();
        }

        _requireStakedGauge(tokenId);

        CompoundState memory state;
        uint24 fee;
        (,, state.token0, state.token1, fee,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        state.positionPool = _getPool(state.token0, state.token1, fee);
        state.owner = owner;

        state.cakeAmount = _claimRewardsToSelf(tokenId);
        if (state.cakeAmount < minReward) {
            revert NotEnoughReward();
        }
        if (state.cakeAmount == 0) {
            return (0, 0, 0);
        }

        state = _swapCakeForPosition(state, rewardSplitBps);
        state = _addLiquidity(state, tokenId, deadline);
        _sendLeftoversAndRewards(state);

        emit RewardsCompounded(tokenId, state.owner, state.cakeAmount, state.amountAdded0, state.amountAdded1);
        return (state.cakeAmount, state.amountAdded0, state.amountAdded1);
    }

    function setCompoundReward(uint64 _totalRewardX64) external override onlyOwner {
        if (_totalRewardX64 > totalRewardX64) {
            revert InvalidConfig();
        }
        totalRewardX64 = _totalRewardX64;
        emit CompoundRewardUpdated(msg.sender, _totalRewardX64);
    }

    function _unstakePosition(uint256 tokenId) internal returns (bool wasStaked) {
        address gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) {
            return false;
        }

        address owner = vault.ownerOf(tokenId);
        uint256 cakeAmount = _withdrawToSelf(tokenId);
        _sendCakeIfAny(owner, cakeAmount);
        nonfungiblePositionManager.safeTransferFrom(address(this), address(vault), tokenId, abi.encode(owner));
        delete tokenIdToGauge[tokenId];
        emit PositionUnstaked(tokenId, owner, gauge);
        return true;
    }

    function _withdrawToSelf(uint256 tokenId) internal returns (uint256 cakeAmount) {
        uint256 cakeBefore = cakeToken.balanceOf(address(this));
        masterChef.withdraw(tokenId, address(this));
        uint256 cakeAfter = cakeToken.balanceOf(address(this));
        if (cakeAfter > cakeBefore) {
            cakeAmount = cakeAfter - cakeBefore;
        }
    }

    function _claimRewardsToSelf(uint256 tokenId) internal returns (uint256 cakeAmount) {
        uint256 cakeBefore = cakeToken.balanceOf(address(this));
        masterChef.harvest(tokenId, address(this));
        uint256 cakeAfter = cakeToken.balanceOf(address(this));
        if (cakeAfter > cakeBefore) {
            cakeAmount = cakeAfter - cakeBefore;
        }
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

    function _sendCakeIfAny(address recipient, uint256 amount) internal {
        if (amount != 0) {
            cakeToken.safeTransfer(recipient, amount);
        }
    }

    function _swapCakeForPosition(CompoundState memory state, uint256 cakeSplitBps)
        internal
        returns (CompoundState memory)
    {
        uint256 requestedCake0 = state.cakeAmount * cakeSplitBps / 10_000;
        uint256 requestedCake1 = state.cakeAmount - requestedCake0;

        (uint256 spentCake0, uint256 amount0Out) =
            _swapCakeToTarget(state.positionPool, state.token0, state.token1, requestedCake0);
        (uint256 spentCake1, uint256 amount1Out) =
            _swapCakeToTarget(state.positionPool, state.token1, state.token0, requestedCake1);

        state.spentCake = spentCake0 + spentCake1;
        state.amount0Out = amount0Out;
        state.amount1Out = amount1Out;
        return state;
    }

    function _swapCakeToTarget(IUniswapV3Pool positionPool, address targetToken, address otherToken, uint256 amountIn)
        internal
        returns (uint256 spentCake, uint256 amountOut)
    {
        if (amountIn == 0) {
            return (0, 0);
        }

        if (targetToken == address(cakeToken)) {
            return (amountIn, amountIn);
        }

        address directPool = rewardBasePools[targetToken];
        if (directPool != address(0)) {
            amountOut = _swapThroughPool(IUniswapV3Pool(directPool), address(cakeToken), targetToken, amountIn);
            return (amountIn, amountOut);
        }

        address intermediatePool = rewardBasePools[otherToken];
        if (intermediatePool == address(0)) {
            revert NotConfigured();
        }

        IUniswapV3Pool intermediateRewardPool = IUniswapV3Pool(intermediatePool);
        RewardSwapValidation memory intermediateValidation =
            _validateRewardSwap(intermediateRewardPool, address(cakeToken), otherToken, amountIn);
        uint256 intermediateAmount = _swapThroughValidatedPool(
            intermediateRewardPool, intermediateValidation, amountIn, intermediateValidation.amountOutMin
        );

        RewardSwapValidation memory targetValidation =
            _validateRewardSwap(positionPool, otherToken, targetToken, intermediateAmount);
        uint256 routeAmountOutMin = _combinedRouteAmountOutMin(intermediateValidation, targetValidation);
        uint256 targetAmountOutMin =
            targetValidation.amountOutMin > routeAmountOutMin ? targetValidation.amountOutMin : routeAmountOutMin;

        amountOut = _swapThroughValidatedPool(positionPool, targetValidation, intermediateAmount, targetAmountOutMin);
        return (amountIn, amountOut);
    }

    function _swapThroughPool(IUniswapV3Pool pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) {
            return 0;
        }

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
        validation.poolToken0 = pool.token0();
        validation.poolToken1 = pool.token1();
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

    function _addLiquidity(CompoundState memory state, uint256 tokenId, uint256 deadline)
        internal
        returns (CompoundState memory)
    {
        uint256 rewardX64 = totalRewardX64;
        state.maxAddAmount0 = state.amount0Out * Q64 / (rewardX64 + Q64);
        state.maxAddAmount1 = state.amount1Out * Q64 / (rewardX64 + Q64);

        if (state.maxAddAmount0 != 0) {
            IERC20(state.token0).safeIncreaseAllowance(address(masterChef), state.maxAddAmount0);
        }
        if (state.maxAddAmount1 != 0) {
            IERC20(state.token1).safeIncreaseAllowance(address(masterChef), state.maxAddAmount1);
        }

        if (state.maxAddAmount0 != 0 || state.maxAddAmount1 != 0) {
            (, state.amountAdded0, state.amountAdded1) = masterChef.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId, state.maxAddAmount0, state.maxAddAmount1, 0, 0, deadline
                )
            );
            state.rewardAmount0 = state.amountAdded0 * rewardX64 / Q64;
            state.rewardAmount1 = state.amountAdded1 * rewardX64 / Q64;
        }

        if (state.maxAddAmount0 != 0) {
            IERC20(state.token0).safeApprove(address(masterChef), 0);
        }
        if (state.maxAddAmount1 != 0) {
            IERC20(state.token1).safeApprove(address(masterChef), 0);
        }

        return state;
    }

    function _sendLeftoversAndRewards(CompoundState memory state) internal {
        uint256 leftoverCake = state.cakeAmount - state.spentCake;
        if (leftoverCake != 0) {
            cakeToken.safeTransfer(state.owner, leftoverCake);
        }

        uint256 leftover0 = state.amount0Out - state.amountAdded0 - state.rewardAmount0;
        uint256 leftover1 = state.amount1Out - state.amountAdded1 - state.rewardAmount1;
        if (leftover0 != 0) {
            IERC20(state.token0).safeTransfer(state.owner, leftover0);
        }
        if (leftover1 != 0) {
            IERC20(state.token1).safeTransfer(state.owner, leftover1);
        }
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
        if (from != address(vault) && from != address(masterChef)) {
            revert Unauthorized();
        }
        if (from == address(masterChef) && tokenIdToGauge[tokenId] != address(masterChef)) {
            revert Unauthorized();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
