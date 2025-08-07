// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./IVault.sol";

/// @title Interface for GaugeManager
interface IGaugeManager {
    function vault() external view returns (IVault);
    function stakePosition(uint256 tokenId) external;
    function unstakePosition(uint256 tokenId) external;
    function claimRewards(uint256 tokenId) external;
    function distributeRewards(uint256 tokenId, address recipient) external;
    function pendingRewards(uint256 tokenId) external view returns (uint256);
    function getPositionGauge(uint256 tokenId) external view returns (address);
    function poolToGauge(address pool) external view returns (address);
}