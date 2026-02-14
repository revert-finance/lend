// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "./interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";
import "./interfaces/aerodrome/IGauge.sol";
import "./interfaces/IVault.sol";
import "./utils/Swapper.sol";

/// @title GaugeManager
/// @notice Vault-only adapter for staking/un-staking and rewarding V3 positions
contract GaugeManager is Ownable2Step, IERC721Receiver, ReentrancyGuard, Swapper {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    error UnexpectedNFT();

    event PositionStaked(uint256 indexed tokenId, address indexed owner);
    event PositionUnstaked(uint256 indexed tokenId, address indexed owner);
    event RewardsCompounded(uint256 indexed tokenId, uint256 aeroAmount, uint256 amount0, uint256 amount1);

    IERC20 public immutable aeroToken;
    IVault public immutable vault;

    // Pool -> gauge mapping and staked position -> gauge mapping
    mapping(address => address) public poolToGauge;
    mapping(uint256 => address) public tokenIdToGauge;

    bool private expectingNft;
    address private expectedNftFrom;
    uint256 private expectedNftTokenId;

    constructor(
        IAerodromeNonfungiblePositionManager _npm,
        IERC20 _aeroToken,
        IVault _vault,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Swapper(
        INonfungiblePositionManager(address(_npm)),
        _universalRouter,
        _zeroxAllowanceHolder
    ) Ownable2Step() {
        aeroToken = _aeroToken;
        vault = _vault;
    }

    modifier onlyVault() {
        if (msg.sender != address(vault)) {
            revert Unauthorized();
        }
        _;
    }

    /// @notice Set gauge for a pool (must match pool's actual gauge)
    function setGauge(address pool, address gauge) external onlyOwner {
        require(gauge != address(0), "Invalid gauge");
        require(IAerodromeSlipstreamPool(pool).gauge() == gauge, "Gauge mismatch");
        poolToGauge[pool] = gauge;
    }

    /// @notice Stake a position from the vault into the gauge
    function stakePosition(uint256 tokenId) external nonReentrant onlyVault {
        address owner = vault.ownerOf(tokenId);
        if (owner == address(0)) {
            revert Unauthorized();
        }

        (,, address token0, address token1, uint24 tickSpacing,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        address pool = IAerodromeSlipstreamFactory(factory).getPool(token0, token1, int24(tickSpacing));
        address gauge = poolToGauge[pool];
        if (gauge == address(0)) {
            revert WrongContract();
        }

        _setExpectedNftTransfer(address(vault), tokenId);
        nonfungiblePositionManager.safeTransferFrom(address(vault), address(this), tokenId);
        nonfungiblePositionManager.approve(gauge, tokenId);
        IGauge(gauge).deposit(tokenId);

        tokenIdToGauge[tokenId] = gauge;
        emit PositionStaked(tokenId, owner);
    }

    /// @notice Unstake a staked position and return it to the vault
    function unstakePosition(uint256 tokenId) external nonReentrant onlyVault {
        address owner = vault.ownerOf(tokenId);
        if (owner == address(0)) {
            revert Unauthorized();
        }

        address gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) {
            revert NotStaked();
        }

        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        uint256 aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;
        if (aeroAmount != 0) {
            _transferRewards(owner, aeroAmount);
        }

        _setExpectedNftTransfer(gauge, tokenId);
        IGauge(gauge).withdraw(tokenId);

        nonfungiblePositionManager.safeTransferFrom(address(this), address(vault), tokenId);
        delete tokenIdToGauge[tokenId];

        emit PositionUnstaked(tokenId, owner);
    }

    /// @notice Compound AERO rewards for a staked position
    function compoundRewards(
        uint256 tokenId,
        bytes calldata swapData0,
        bytes calldata swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external nonReentrant onlyVault returns (uint256 aeroAmount, uint256 amount0Added, uint256 amount1Added) {
        require(aeroSplitBps <= 10000, "Invalid split");

        address owner = vault.ownerOf(tokenId);
        if (owner == address(0)) {
            revert Unauthorized();
        }

        address gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) {
            revert NotStaked();
        }

        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;
        if (aeroAmount == 0) {
            return (0, 0, 0);
        }

        _setExpectedNftTransfer(gauge, tokenId);
        IGauge(gauge).withdraw(tokenId);
        (amount0Added, amount1Added) =
            _compoundIntoPosition(tokenId, owner, aeroAmount, swapData0, swapData1, minAmount0, minAmount1, aeroSplitBps, deadline);

        nonfungiblePositionManager.approve(gauge, tokenId);
        IGauge(gauge).deposit(tokenId);
        return (aeroAmount, amount0Added, amount1Added);
    }

    /// @notice Simple reward claiming without compounding
    function claimRewards(uint256 tokenId, address recipient) external nonReentrant onlyVault returns (uint256 aeroAmount) {
        address owner = vault.ownerOf(tokenId);
        if (owner == address(0) || recipient == address(0)) {
            revert Unauthorized();
        }

        address gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) {
            revert NotStaked();
        }

        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;
        if (aeroAmount != 0) {
            _transferRewards(recipient, aeroAmount);
        }
        return aeroAmount;
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(nonfungiblePositionManager) || !expectingNft || from != expectedNftFrom || tokenId != expectedNftTokenId) {
            revert UnexpectedNFT();
        }
        _clearExpectedNftTransfer();

        return IERC721Receiver.onERC721Received.selector;
    }

    function _transferRewards(address account, uint256 amount) internal {
        aeroToken.safeTransfer(account, amount);
    }

    function _setExpectedNftTransfer(address from, uint256 tokenId) internal {
        expectingNft = true;
        expectedNftFrom = from;
        expectedNftTokenId = tokenId;
    }

    function _clearExpectedNftTransfer() internal {
        expectingNft = false;
        expectedNftFrom = address(0);
        expectedNftTokenId = 0;
    }

    /// @notice Internal function to compound AERO into a position
    function _compoundIntoPosition(
        uint256 tokenId,
        address owner,
        uint256 aeroAmount,
        bytes memory swapData0,
        bytes memory swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 aeroSplitBps,
        uint256 deadline
    ) internal returns (uint256 amount0Added, uint256 amount1Added) {
        if (owner == address(0) || aeroAmount == 0) {
            return (0, 0);
        }
        if (swapData0.length == 0) {
            require(aeroSplitBps == 0, "Missing swapData0");
        }
        if (swapData1.length == 0) {
            require(aeroSplitBps == 10000, "Missing swapData1");
        }

        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);

        // Swap AERO to position tokens
        uint256 amount0;
        uint256 amount1;
        uint256 aeroForToken0 = 0;

        uint256 aeroSpent;
        if (swapData0.length > 0) {
            aeroForToken0 = (aeroAmount * aeroSplitBps) / 10000;
            if (aeroForToken0 > 0) {
                (aeroSpent, amount0) = _routerSwap(
                    RouterSwapParams(
                        aeroToken,
                        IERC20(token0),
                        aeroForToken0,
                        minAmount0,
                        swapData0
                    )
                );
            }
        }

        if (swapData1.length > 0) {
            uint256 remainingAero = aeroAmount - aeroForToken0;
            if (remainingAero > 0) {
                uint256 amount1Spent;
                (amount1Spent, amount1) = _routerSwap(
                    RouterSwapParams(
                        aeroToken,
                        IERC20(token1),
                        remainingAero,
                        minAmount1,
                        swapData1
                    )
                );
                aeroSpent += amount1Spent;
            }
        }

        uint256 unswappedAero = aeroAmount - aeroSpent;
        if (unswappedAero > 0) {
            SafeERC20.safeTransfer(aeroToken, owner, unswappedAero);
        }

        if (amount0 != 0 || amount1 != 0) {
            SafeERC20.safeIncreaseAllowance(IERC20(token0), address(nonfungiblePositionManager), amount0);
            SafeERC20.safeIncreaseAllowance(IERC20(token1), address(nonfungiblePositionManager), amount1);

            (, amount0Added, amount1Added) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId,
                    amount0.toUint128(),
                    amount1.toUint128(),
                    0,
                    0,
                    deadline
                )
            );

            SafeERC20.safeApprove(IERC20(token0), address(nonfungiblePositionManager), 0);
            SafeERC20.safeApprove(IERC20(token1), address(nonfungiblePositionManager), 0);

            uint256 leftover0 = amount0 - amount0Added;
            uint256 leftover1 = amount1 - amount1Added;
            if (leftover0 > 0) SafeERC20.safeTransfer(IERC20(token0), owner, leftover0);
            if (leftover1 > 0) SafeERC20.safeTransfer(IERC20(token1), owner, leftover1);
        }

        emit RewardsCompounded(tokenId, aeroAmount, amount0Added, amount1Added);
        return (amount0Added, amount1Added);
    }
}
