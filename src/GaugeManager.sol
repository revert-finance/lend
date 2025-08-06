// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "./interfaces/aerodrome/IGauge.sol";
import "./interfaces/IVault.sol";
import "./utils/Constants.sol";

/// @title Gauge Manager for Aerodrome LP positions
/// @notice Manages gauge staking, reward claiming, and distribution for Revert Lend positions
contract GaugeManager is Ownable2Step, IERC721Receiver, ReentrancyGuard, Constants {
    using SafeERC20 for IERC20;

    event GaugeSet(address indexed pool, address indexed gauge);
    event PositionStaked(uint256 indexed tokenId, address indexed gauge);
    event PositionUnstaked(uint256 indexed tokenId, address indexed gauge);
    event RewardsClaimed(uint256 indexed tokenId, address indexed gauge, uint256 amount);
    event RewardsDistributed(address indexed recipient, uint256 amount);

    /// @notice Position manager for Aerodrome positions
    IAerodromeNonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice AERO token address
    IERC20 public immutable aeroToken;

    /// @notice V3Vault that owns the positions
    IVault public immutable vault;

    /// @notice Aerodrome factory address
    address public immutable factory;

    /// @notice Mapping from pool address to gauge address
    mapping(address => address) public poolToGauge;

    /// @notice Mapping from tokenId to gauge where it's staked
    mapping(uint256 => address) public tokenIdToGauge;

    /// @notice Accumulated rewards per tokenId
    mapping(uint256 => uint256) public accumulatedRewards;

    /// @param _nonfungiblePositionManager Aerodrome position manager
    /// @param _aeroToken AERO token address
    /// @param _vault V3Vault address
    constructor(
        IAerodromeNonfungiblePositionManager _nonfungiblePositionManager,
        IERC20 _aeroToken,
        IVault _vault
    ) Ownable2Step() {
        nonfungiblePositionManager = _nonfungiblePositionManager;
        aeroToken = _aeroToken;
        vault = _vault;
        factory = _nonfungiblePositionManager.factory();
    }

    /// @notice Set gauge for a specific pool (onlyOwner)
    /// @param pool The pool address
    /// @param gauge The gauge address
    function setGauge(address pool, address gauge) external onlyOwner {
        poolToGauge[pool] = gauge;
        emit GaugeSet(pool, gauge);
    }

    /// @notice Stake a position in its corresponding gauge
    /// @param tokenId The position token ID to stake
    function stakePosition(uint256 tokenId) external nonReentrant {
        // Only vault can call this
        if (msg.sender != address(vault)) revert Unauthorized();

        // Get position details
        (,, address token0, address token1, uint24 tickSpacing,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        
        // Get pool address from factory
        address pool = IAerodromeSlipstreamFactory(factory).getPool(token0, token1, int24(uint24(tickSpacing)));
        
        // Get gauge for this pool
        address gauge = poolToGauge[pool];
        if (gauge == address(0)) revert GaugeNotSet();

        // Check if already staked
        if (tokenIdToGauge[tokenId] != address(0)) revert AlreadyStaked();

        // Transfer NFT from vault to this contract
        nonfungiblePositionManager.safeTransferFrom(address(vault), address(this), tokenId);

        // Approve gauge to spend NFT
        nonfungiblePositionManager.approve(gauge, tokenId);

        // Stake in gauge
        IGauge(gauge).deposit(tokenId);

        // Record staking
        tokenIdToGauge[tokenId] = gauge;

        emit PositionStaked(tokenId, gauge);
    }

    /// @notice Unstake a position from its gauge
    /// @param tokenId The position token ID to unstake
    function unstakePosition(uint256 tokenId) external nonReentrant {
        // Only vault can call this
        if (msg.sender != address(vault)) revert Unauthorized();

        address gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) revert NotStaked();

        // Claim any pending rewards first
        _claimRewards(tokenId, gauge);

        // Withdraw from gauge
        IGauge(gauge).withdraw(tokenId);

        // Transfer NFT back to vault
        nonfungiblePositionManager.safeTransferFrom(address(this), address(vault), tokenId);

        // Clear staking record
        delete tokenIdToGauge[tokenId];

        emit PositionUnstaked(tokenId, gauge);
    }

    /// @notice Claim rewards for a staked position
    /// @param tokenId The position token ID
    function claimRewards(uint256 tokenId) external nonReentrant {
        address gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) revert NotStaked();

        _claimRewards(tokenId, gauge);
    }

    /// @notice Claim rewards for multiple positions
    /// @param tokenIds Array of position token IDs
    function claimRewardsMultiple(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            address gauge = tokenIdToGauge[tokenIds[i]];
            if (gauge != address(0)) {
                _claimRewards(tokenIds[i], gauge);
            }
        }
    }

    /// @notice Distribute accumulated rewards to a recipient
    /// @param tokenId The position token ID
    /// @param recipient The address to receive rewards
    function distributeRewards(uint256 tokenId, address recipient) external nonReentrant {
        // Only vault can call this
        if (msg.sender != address(vault)) revert Unauthorized();

        uint256 rewards = accumulatedRewards[tokenId];
        if (rewards == 0) revert NotEnoughReward();

        // Clear accumulated rewards
        accumulatedRewards[tokenId] = 0;

        // Transfer rewards
        aeroToken.safeTransfer(recipient, rewards);

        emit RewardsDistributed(recipient, rewards);
    }

    /// @notice Get the gauge address for a position
    /// @param tokenId The position token ID
    /// @return The gauge address or address(0) if not staked
    function getPositionGauge(uint256 tokenId) external view returns (address) {
        return tokenIdToGauge[tokenId];
    }

    /// @notice Get pending rewards for a position
    /// @param tokenId The position token ID
    /// @return The pending reward amount
    function pendingRewards(uint256 tokenId) external view returns (uint256) {
        address gauge = tokenIdToGauge[tokenId];
        if (gauge == address(0)) return 0;
        
        return IGauge(gauge).earned(address(this)) + accumulatedRewards[tokenId];
    }

    /// @notice Internal function to claim rewards
    function _claimRewards(uint256 tokenId, address gauge) internal {
        uint256 balanceBefore = aeroToken.balanceOf(address(this));
        
        // Claim from gauge
        IGauge(gauge).getReward();
        
        uint256 balanceAfter = aeroToken.balanceOf(address(this));
        uint256 claimed = balanceAfter - balanceBefore;
        
        if (claimed > 0) {
            accumulatedRewards[tokenId] += claimed;
            emit RewardsClaimed(tokenId, gauge, claimed);
        }
    }

    /// @notice Handle NFT transfers (required for IERC721Receiver)
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}