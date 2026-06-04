// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IPancakeMasterChefV3Staker {
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function transformedTokenId() external view returns (uint256 tokenId);
    function custodyOf(uint256 tokenId) external view returns (address nftOwner);
    function isManaged(uint256 tokenId) external view returns (bool managed);
    function isStaked(uint256 tokenId) external view returns (bool staked);
    function approveTransform(uint256 tokenId, address target, bool active) external;
    function transform(uint256 tokenId, address transformer, bytes calldata data) external returns (uint256 newTokenId);
    function transformWithRewardCompound(uint256 tokenId, address transformer, bytes calldata data)
        external
        returns (uint256 newTokenId);
    function compoundRewards(uint256 tokenId, address transformer, bytes calldata data)
        external
        returns (uint256 newTokenId);
}

interface IPancakeMasterChefV3RewardTransformer {
    function executeWithReward(uint256 tokenId, address owner, uint256 cakeAmount, bytes calldata data) external;
}
