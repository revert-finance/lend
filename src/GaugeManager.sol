// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "./interfaces/aerodrome/IGauge.sol";
import "./utils/Swapper.sol";

/// @notice Gauge helper for vaulted positions.
contract GaugeManager is Ownable2Step, ReentrancyGuard, IERC721Receiver, Swapper, IGaugeManager {
    using SafeERC20 for IERC20;

    uint64 public constant MAX_REWARD_X64 = 368_934_881_474_191_032; // floor(Q64 / 50)
    // Reward compounding validates each fixed route hop against both TWAP deviation and a minimum output bound
    // derived from the current pool price before executing the swap.
    uint32 private constant REWARD_TWAP_SECONDS = 60;
    uint16 private constant REWARD_MAX_TWAP_TICK_DIFFERENCE = 200;
    uint64 private constant REWARD_MAX_PRICE_DIFFERENCE_X64 = 368_934_881_474_191_032; // floor(Q64 / 50)

    IERC20 public immutable aeroToken;
    IVault public immutable vault;
    address public override withdrawer;
    uint64 public totalRewardX64 = MAX_REWARD_X64; // 2%

    mapping(address => address) public override poolToGauge;
    mapping(uint256 => address) public override tokenIdToGauge;
    mapping(address => address) public override rewardBasePools;

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

    function withdrawBalances(address[] calldata tokens, address to) external override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        address token;
        uint256 balance;
        for (; i < count; ++i) {
            token = tokens[i];
            balance = IERC20(token).balanceOf(address(this));
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
        IGauge(gauge).deposit(tokenId);
        // Slipstream CLGauge.deposit triggers NPM.collect to msg.sender, so any pre-stake accrued token0/token1
        // fees are realized during staking and forwarded here to the position owner.
        _sendDepositDeltas(token0, token1, owner, token0Before, token1Before);

        // NOTE FOR AUDITS:
        // We intentionally do not enforce `ownerOf(tokenId) == gauge` post-deposit here.
        // Some gauge implementations may custody via intermediate contracts/wrappers while still exposing
        // the configured gauge as the canonical integration endpoint for getReward/withdraw.
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
        _claimAndSendRewardsBestEffort(gauge, tokenId, owner);
        IGauge(gauge).withdraw(tokenId);
        // Intentionally no token0/token1 forwarding on plain unstake:
        // while staked in Slipstream gauge, swap fees accrue to gauge-side accounting (not as NFT collectable fees),
        // and CLGauge.deposit already collects any pre-stake NFT fees when staking.
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
        aeroAmount = _claimAndSendRewards(gauge, tokenId, recipient);
        emit RewardsClaimed(tokenId, owner, aeroAmount);
    }

    function compoundRewards(
        uint256 tokenId,
        uint256 minAeroReward,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external override nonReentrant returns (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) {
        address owner = _requireVaultOrOwner(tokenId);
        if (aeroSplitBps > 10_000) {
            revert InvalidConfig();
        }

        CompoundState memory state;
        state.gauge = _requireStakedGauge(tokenId);
        uint24 feeOrTickSpacing;
        (,, state.token0, state.token1, feeOrTickSpacing,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        state.positionPool = _getPool(state.token0, state.token1, feeOrTickSpacing);
        state.owner = owner;

        state.aeroAmount = _claimRewardsToSelf(state.gauge, tokenId);
        if (state.aeroAmount < minAeroReward) {
            revert NotEnoughReward();
        }
        if (state.aeroAmount == 0) {
            return (0, 0, 0);
        }

        IGauge(state.gauge).withdraw(tokenId);
        state = _swapAeroForPosition(state, aeroSplitBps);
        state = _addLiquidity(state, tokenId, deadline);
        uint256 token0BeforeDeposit = IERC20(state.token0).balanceOf(address(this));
        uint256 token1BeforeDeposit = IERC20(state.token1).balanceOf(address(this));
        nonfungiblePositionManager.approve(state.gauge, tokenId);
        IGauge(state.gauge).deposit(tokenId);
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

    function _claimAndSendRewards(address gauge, uint256 tokenId, address recipient)
        internal
        returns (uint256 aeroAmount)
    {
        aeroAmount = _claimRewardsToSelf(gauge, tokenId);
        _sendAeroIfAny(recipient, aeroAmount);
    }

    function _claimAndSendRewardsBestEffort(address gauge, uint256 tokenId, address recipient) internal {
        uint256 aeroAmount = _claimRewardsToSelfBestEffort(gauge, tokenId);
        _sendAeroIfAny(recipient, aeroAmount);
    }

    function _claimRewardsToSelf(address gauge, uint256 tokenId) internal returns (uint256 aeroAmount) {
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;
    }

    function _claimRewardsToSelfBestEffort(address gauge, uint256 tokenId) internal returns (uint256 aeroAmount) {
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        // Liveness over reward payout: unstake/remove/liquidation must not depend on a successful reward claim.
        try IGauge(gauge).getReward(tokenId) {
            uint256 aeroAfter = aeroToken.balanceOf(address(this));
            if (aeroAfter > aeroBefore) {
                aeroAmount = aeroAfter - aeroBefore;
            }
        } catch {}
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

        (uint256 spentAero0, uint256 amount0Out) =
            _swapAeroToTarget(state.positionPool, state.token0, state.token1, requestedAero0);
        (uint256 spentAero1, uint256 amount1Out) =
            _swapAeroToTarget(state.positionPool, state.token1, state.token0, requestedAero1);

        state.spentAero = spentAero0 + spentAero1;
        state.amount0Out = amount0Out;
        state.amount1Out = amount1Out;
        return state;
    }

    function _swapAeroToTarget(IUniswapV3Pool positionPool, address targetToken, address otherToken, uint256 amountIn)
        internal
        returns (uint256 spentAero, uint256 amountOut)
    {
        if (amountIn == 0) {
            return (0, 0);
        }

        if (targetToken == address(aeroToken)) {
            return (amountIn, amountIn);
        }

        address directPool = rewardBasePools[targetToken];
        if (directPool != address(0)) {
            amountOut = _swapThroughPool(IUniswapV3Pool(directPool), address(aeroToken), targetToken, amountIn);
            return (amountIn, amountOut);
        }

        address intermediatePool = rewardBasePools[otherToken];
        if (intermediatePool == address(0)) {
            revert NotConfigured();
        }

        uint256 intermediateAmount =
            _swapThroughPool(IUniswapV3Pool(intermediatePool), address(aeroToken), otherToken, amountIn);
        amountOut = _swapThroughPool(positionPool, otherToken, targetToken, intermediateAmount);
        return (amountIn, amountOut);
    }

    function _swapThroughPool(IUniswapV3Pool pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) {
            return 0;
        }

        address poolToken0 = IAerodromeSlipstreamPool(address(pool)).token0();
        address poolToken1 = IAerodromeSlipstreamPool(address(pool)).token1();
        bool swap0For1;
        if (poolToken0 == tokenIn && poolToken1 == tokenOut) {
            swap0For1 = true;
        } else if (poolToken0 == tokenOut && poolToken1 == tokenIn) {
            swap0For1 = false;
        } else {
            revert InvalidPool();
        }

        (uint160 sqrtPriceX96, int24 currentTick) = _getPoolSlot0(pool);
        uint256 amountOutMin = _validateSwap(
            swap0For1,
            amountIn,
            pool,
            currentTick,
            sqrtPriceX96,
            REWARD_TWAP_SECONDS,
            REWARD_MAX_TWAP_TICK_DIFFERENCE,
            REWARD_MAX_PRICE_DIFFERENCE_X64
        );
        (, amountOut) = _poolSwap(
            PoolSwapParams({
                pool: pool,
                token0: IERC20(poolToken0),
                token1: IERC20(poolToken1),
                fee: _poolFeeOrTickSpacing(pool),
                swap0For1: swap0For1,
                amountIn: amountIn,
                amountOutMin: amountOutMin
            })
        );
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
        uint256 rewardX64 = totalRewardX64;
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
