// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "./interfaces/aerodrome/IGauge.sol";
import "./utils/Swapper.sol";

/// @notice Gauge helper for vaulted positions. All user entrypoints should go through V3Vault.
contract GaugeManager is Ownable2Step, ReentrancyGuard, IERC721Receiver, Swapper, IGaugeManager {
    using SafeERC20 for IERC20;

    IERC20 public immutable aeroToken;
    IVault public immutable vault;

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
        uint256 amountAdded0;
        uint256 amountAdded1;
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

        nonfungiblePositionManager.safeTransferFrom(address(vault), address(this), tokenId);
        nonfungiblePositionManager.approve(gauge, tokenId);
        IGauge(gauge).deposit(tokenId);

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
        _requireVaultCaller();
        address gauge = _requireStakedGauge(tokenId);

        address owner = vault.ownerOf(tokenId);
        aeroAmount = _claimAndSendRewards(gauge, tokenId, recipient);
        emit RewardsClaimed(tokenId, owner, aeroAmount);
    }

    function compoundRewards(
        uint256 tokenId,
        bytes calldata swapData0,
        bytes calldata swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external override nonReentrant returns (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) {
        _requireVaultCaller();
        if (aeroSplitBps > 10_000) {
            revert InvalidConfig();
        }

        CompoundState memory state;
        state.gauge = _requireStakedGauge(tokenId);

        state.owner = vault.ownerOf(tokenId);
        state.aeroAmount = _claimRewardsToSelf(state.gauge, tokenId);
        if (state.aeroAmount == 0) {
            return (0, 0, 0);
        }

        IGauge(state.gauge).withdraw(tokenId);
        (,, state.token0, state.token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);

        state = _swapAeroForPosition(state, aeroSplitBps, swapData0, swapData1, minAmount0, minAmount1);
        state = _addLiquidity(state, tokenId, deadline);
        _sendLeftovers(state);

        nonfungiblePositionManager.approve(state.gauge, tokenId);
        IGauge(state.gauge).deposit(tokenId);

        emit RewardsCompounded(tokenId, state.owner, state.aeroAmount, state.amountAdded0, state.amountAdded1);
        return (state.aeroAmount, state.amountAdded0, state.amountAdded1);
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

    function _addLiquidity(CompoundState memory state, uint256 tokenId, uint256 deadline)
        internal
        returns (CompoundState memory)
    {
        if (state.amount0Out != 0) {
            IERC20(state.token0).safeIncreaseAllowance(address(nonfungiblePositionManager), state.amount0Out);
        }
        if (state.amount1Out != 0) {
            IERC20(state.token1).safeIncreaseAllowance(address(nonfungiblePositionManager), state.amount1Out);
        }

        if (state.amount0Out != 0 || state.amount1Out != 0) {
            (, state.amountAdded0, state.amountAdded1) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId, state.amount0Out, state.amount1Out, 0, 0, deadline
                )
            );
        }

        if (state.amount0Out != 0) {
            IERC20(state.token0).safeApprove(address(nonfungiblePositionManager), 0);
        }
        if (state.amount1Out != 0) {
            IERC20(state.token1).safeApprove(address(nonfungiblePositionManager), 0);
        }

        return state;
    }

    function _sendLeftovers(CompoundState memory state) internal {
        uint256 leftoverAero = state.aeroAmount - state.spentAero;
        if (leftoverAero != 0) {
            aeroToken.safeTransfer(state.owner, leftoverAero);
        }

        uint256 leftover0 = state.amount0Out - state.amountAdded0;
        uint256 leftover1 = state.amount1Out - state.amountAdded1;
        if (leftover0 != 0) {
            IERC20(state.token0).safeTransfer(state.owner, leftover0);
        }
        if (leftover1 != 0) {
            IERC20(state.token1).safeTransfer(state.owner, leftover1);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }
        // NOTE FOR AUDITS:
        // Direct NFT sends to GaugeManager are intentionally outside protocol flows. Such NFTs are not tracked in
        // tokenIdToGauge and recoverability is not guaranteed by design. Users must interact through V3Vault only.
        return IERC721Receiver.onERC721Received.selector;
    }
}
