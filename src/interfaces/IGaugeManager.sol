// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./IProtocolFeeController.sol";

interface IGaugeManager is IProtocolFeeController {
    event PositionStaked(uint256 indexed tokenId, address indexed owner, address indexed gauge);
    event PositionUnstaked(uint256 indexed tokenId, address indexed owner, address indexed gauge);
    event RewardsClaimed(uint256 indexed tokenId, address indexed owner, uint256 aeroAmount);
    event RewardsCompounded(
        uint256 indexed tokenId, address indexed owner, uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1
    );
    event CompoundRewardUpdated(address account, uint64 totalRewardX64);
    event GaugeSet(address indexed pool, address indexed gauge);
    event RewardBasePoolSet(address indexed baseToken, address indexed pool);

    function poolToGauge(address pool) external view returns (address);
    function tokenIdToGauge(uint256 tokenId) external view returns (address);
    function rewardBasePools(address baseToken) external view returns (address pool);

    function setGauge(address pool, address gauge) external;
    function setRewardBasePool(address baseToken, address pool) external;

    function stakePosition(uint256 tokenId) external;
    function unstakePosition(uint256 tokenId) external;
    function unstakeIfStaked(uint256 tokenId) external returns (bool wasStaked);

    function claimRewards(uint256 tokenId, address recipient) external returns (uint256 aeroAmount);

    function compoundRewards(
        uint256 tokenId,
        uint256 minAeroReward,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external returns (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1);

    function setCompoundReward(uint64 _totalRewardX64) external;
}
