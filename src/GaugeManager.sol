// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IV3Oracle.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "./interfaces/aerodrome/IGauge.sol";
import "./utils/Swapper.sol";

interface IVaultOracleProvider {
    function oracle() external view returns (IV3Oracle);
}

/// @notice Gauge helper for vaulted positions.
contract GaugeManager is Ownable2Step, ReentrancyGuard, IERC721Receiver, Swapper, IGaugeManager {
    using SafeERC20 for IERC20;

    uint64 public constant MAX_REWARD_X64 = 368_934_881_474_191_032; // floor(Q64 / 50)
    uint64 private constant REWARD_VALUE_VALIDATION_SLIPPAGE_X64 = 368_934_881_474_191_032; // floor(Q64 / 50)

    IERC20 public immutable aeroToken;
    IVault public immutable vault;
    address public override withdrawer;
    uint64 public totalRewardX64 = MAX_REWARD_X64; // 2%

    mapping(address => address) public override poolToGauge;
    mapping(uint256 => address) public override tokenIdToGauge;

    struct CompoundState {
        address gauge;
        address owner;
        address token0;
        address token1;
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
        uint256 token0After = IERC20(token0).balanceOf(address(this));
        uint256 token1After = IERC20(token1).balanceOf(address(this));
        if (token0After > token0Before) {
            IERC20(token0).safeTransfer(owner, token0After - token0Before);
        }
        if (token1After > token1Before) {
            IERC20(token1).safeTransfer(owner, token1After - token1Before);
        }

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
        bytes calldata swapData0,
        bytes calldata swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
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
        (,, state.token0, state.token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        state.owner = owner;

        state.aeroAmount = _claimRewardsToSelf(state.gauge, tokenId);
        if (state.aeroAmount < minAeroReward) {
            revert NotEnoughReward();
        }
        if (state.aeroAmount == 0) {
            return (0, 0, 0);
        }

        IGauge(state.gauge).withdraw(tokenId);

        state = _swapAeroForPosition(state, aeroSplitBps, swapData0, swapData1, minAmount0, minAmount1);
        _validateRewardValueIfPossible(state);
        state = _addLiquidity(state, tokenId, deadline);
        nonfungiblePositionManager.approve(state.gauge, tokenId);
        IGauge(state.gauge).deposit(tokenId);
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

    function _swapAeroForPosition(
        CompoundState memory state,
        uint256 aeroSplitBps,
        bytes calldata swapData0,
        bytes calldata swapData1,
        uint256 minAmount0,
        uint256 minAmount1
    ) internal returns (CompoundState memory) {
        if (swapData0.length != 0) {
            uint256 requestedAero0 = state.aeroAmount * aeroSplitBps / 10_000;
            (uint256 amountInDelta0, uint256 amountOutDelta0) =
                _routerSwap(RouterSwapParams(aeroToken, IERC20(state.token0), requestedAero0, minAmount0, swapData0));
            state.spentAero += amountInDelta0;
            state.amount0Out += amountOutDelta0;
        }

        if (swapData1.length != 0) {
            uint256 remainingAero = state.aeroAmount - state.spentAero;
            (uint256 amountInDelta1, uint256 amountOutDelta1) =
                _routerSwap(RouterSwapParams(aeroToken, IERC20(state.token1), remainingAero, minAmount1, swapData1));
            state.spentAero += amountInDelta1;
            state.amount1Out += amountOutDelta1;
        }

        // If one side of the position is AERO itself, any unswapped rewards can be added directly as liquidity.
        uint256 unswappedAero = state.aeroAmount - state.spentAero;
        if (unswappedAero != 0) {
            if (state.token0 == address(aeroToken)) {
                state.amount0Out += unswappedAero;
                state.spentAero += unswappedAero;
            } else if (state.token1 == address(aeroToken)) {
                state.amount1Out += unswappedAero;
                state.spentAero += unswappedAero;
            }
        }

        return state;
    }

    function _validateRewardValueIfPossible(CompoundState memory state) internal view {
        // Accepted trust boundary for long-tail pools: if the vault/oracle cannot price AERO or either output token,
        // reward-compound validation is skipped and users rely on operator honesty for that pool.
        IV3Oracle oracle = IVaultOracleProvider(address(vault)).oracle();

        if (address(oracle) == address(0) || address(oracle).code.length == 0) {
            return;
        }

        if (!oracle.isTokenConfigured(address(aeroToken))) {
            return;
        }
        if (!oracle.isTokenConfigured(state.token0)) {
            return;
        }
        if (!oracle.isTokenConfigured(state.token1)) {
            return;
        }

        uint256 aeroValue = state.aeroAmount;

        uint256 returnedValue;
        if (state.amount0Out != 0) {
            returnedValue += oracle.getTokenValue(state.token0, state.amount0Out, address(aeroToken));
        }
        if (state.amount1Out != 0) {
            returnedValue += oracle.getTokenValue(state.token1, state.amount1Out, address(aeroToken));
        }

        uint256 leftoverAero = state.aeroAmount - state.spentAero;
        if (leftoverAero != 0 && state.token0 != address(aeroToken) && state.token1 != address(aeroToken)) {
            returnedValue += leftoverAero;
        }

        uint256 minReturnedValue =
            Math.mulDiv(aeroValue, uint256(Q64) - REWARD_VALUE_VALIDATION_SLIPPAGE_X64, uint256(Q64));
        if (returnedValue < minReturnedValue) {
            revert SlippageError();
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
