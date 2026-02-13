// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./IVault.sol";

interface IGaugeManager {
    // Events
    event PositionStaked(uint256 indexed tokenId, address indexed owner);
    event PositionUnstaked(uint256 indexed tokenId, address indexed owner);
    event RewardsCompounded(uint256 indexed tokenId, uint256 aeroAmount, uint256 amount0, uint256 amount1);
    event RewardUpdated(address account, uint64 totalRewardX64);
    event FeeWithdrawerUpdated(address withdrawer);
    event FeesWithdrawn(address token, address to, uint256 amount);

    function aeroToken() external view returns (IERC20);
    function vault() external view returns (IVault);

    function poolToGauge(address pool) external view returns (address);
    function tokenIdToGauge(uint256 tokenId) external view returns (address);

    // Core functions
    function stakePosition(uint256 tokenId) external;
    function unstakePosition(uint256 tokenId) external;

    // Compounding
    function compoundRewards(
        uint256 tokenId,
        bytes calldata swapData0,
        bytes calldata swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external;

    // Simple claim without compounding
    function claimRewards(uint256 tokenId) external;

    // Admin functions
    function setGauge(address pool, address gauge) external;
    function setReward(uint64 _totalRewardX64) external;
    function setFeeWithdrawer(address _feeWithdrawer) external;
    function withdrawFees(address[] calldata tokens, address to) external;

    function totalRewardX64() external view returns (uint64);
    function feeWithdrawer() external view returns (address);
}
