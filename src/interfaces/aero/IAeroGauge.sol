// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Aero CLGauge subset, pinned to metadex-slipstream-public cbee64820898fbce295292a510522694eccc60c5.
interface IAeroGauge {
    function voter() external view returns (address);
    function nft() external view returns (address);
    function pool() external view returns (address);
    function deferredEmissions(address account) external view returns (uint256);
    function earned(address account, uint256[] calldata tokenIds) external view returns (uint256);
    function claimEmissions(address account, address recipient, uint256[] calldata tokenIds) external;
    function withdraw(uint256 tokenId) external;
}

/// @dev Core snapshot 0058bd9b1d49b0fb0a6d130dd51886b2c64e3d99; direct leaf delivery only.
interface IAeroLeafVoter {
    function RECEIPT_TOKEN() external view returns (address);
    function EMISSIONS_HANDLER() external view returns (address);
}

interface IAeroLeafEmissionsHandler {
    function LEAF_VOTER() external view returns (address);
    function RECEIPT_TOKEN() external view returns (address);
}
