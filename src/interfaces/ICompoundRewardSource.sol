// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Answers which reward rate (Q64) every compound of a position pays; implemented by AutoRangeAndCompound
/// from the position's compound mode (Simple / Advanced).
interface ICompoundRewardSource {
    function compoundRewardX64(uint256 tokenId) external view returns (uint64);
}
