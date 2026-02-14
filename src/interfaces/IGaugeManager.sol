// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./IVault.sol";

interface IGaugeManager {
    // Events
    event PositionStaked(uint256 indexed tokenId, address indexed owner);
    event PositionUnstaked(uint256 indexed tokenId, address indexed owner);
    event RewardsCompounded(uint256 indexed tokenId, uint256 aeroAmount, uint256 amount0, uint256 amount1);

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
    ) external returns (uint256 aeroAmount, uint256 amount0Added, uint256 amount1Added);

    // Simple claim without compounding
    function claimRewards(uint256 tokenId, address recipient) external returns (uint256 aeroAmount);

    // Admin functions
    function setGauge(address pool, address gauge) external;
}
