// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IPancakeMasterChefV3Staker {
    enum RewardToken {
        CAKE,
        TOKEN0,
        TOKEN1
    }

    struct RewardCompoundParams {
        uint256 minCakeReward;
        uint256 cakeSplitBps;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function ownerOf(uint256 tokenId) external view returns (address owner);
    function transformedTokenId() external view returns (uint256 tokenId);
    function custodyOf(uint256 tokenId) external view returns (address nftOwner);
    function isManaged(uint256 tokenId) external view returns (bool managed);
    function isStaked(uint256 tokenId) external view returns (bool staked);
    function approveTransform(uint256 tokenId, address target, bool active) external;
    function setHarvestToken(uint256 tokenId, RewardToken rewardToken) external;
    function claimRewards(uint256 tokenId, address recipient) external returns (uint256 rewardAmount);
    function compoundRewards(uint256 tokenId, RewardCompoundParams calldata params)
        external
        returns (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1);
    function transform(uint256 tokenId, address transformer, bytes calldata data) external returns (uint256 newTokenId);
    function transformWithRewardCompound(
        uint256 tokenId,
        address transformer,
        bytes calldata data,
        RewardCompoundParams calldata params
    ) external returns (uint256 newTokenId);
}
