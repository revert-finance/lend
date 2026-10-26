// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Aero CLGauge subset, pinned to metadex-slipstream-public cbee64820898fbce295292a510522694eccc60c5.
interface IAeroGauge {
    function voter() external view returns (address);
    function gaugeFactory() external view returns (address);
    function nft() external view returns (address);
    function pool() external view returns (address);
    function depositBlock(uint256 tokenId) external view returns (uint256);
    function deferredEmissions(address account) external view returns (uint256);
    function earned(address account, uint256[] calldata tokenIds) external view returns (uint256);
    function claimEmissions(address account, address recipient, uint256[] calldata tokenIds) external;
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
}

/// @dev CLGaugeFactory returns `PenaltyConfig{minStakeBlocks, penaltyRate}`: two static words, decoded as a pair here.
/// Gauge._applyPenalty forfeits `penaltyRate / 1e6` of a claim while `block.number < depositBlock + minStakeBlocks`.
interface IAeroGaugeFactory {
    function effectivePenaltyConfig(address gauge) external view returns (uint256 minStakeBlocks, uint256 penaltyRate);
}

/// @dev Core snapshot 0058bd9b1d49b0fb0a6d130dd51886b2c64e3d99. The voter mints the receipt token to its
/// EMISSIONS_HANDLER, which either delivers it to the recipients (LeafEmissionsHandler, leaf chains) or redeems it into
/// the root token (RootEmissionsHandler, root chain).
interface IAeroLeafVoter {
    function RECEIPT_TOKEN() external view returns (address);
    function EMISSIONS_HANDLER() external view returns (address);
    /// @dev Smallest receipt amount `redeem` accepts; the root handler parks smaller legs (see IAeroRootEmissionsHandler)
    function MIN_REDEEM_AMOUNT() external view returns (uint256);
}

/// @dev Leaf delivery: every leg transfers RECEIPT_TOKEN to its recipient.
interface IAeroLeafEmissionsHandler {
    function LEAF_VOTER() external view returns (address);
    function RECEIPT_TOKEN() external view returns (address);
}

/// @dev Root redemption (no RECEIPT_TOKEN getter): a leg that lifts the recipient's pending total to
/// MIN_REDEEM_AMOUNT redeems that whole total synchronously into the root token, a smaller leg stays in
/// `pendingRedeems[recipient]` until a later leg of the same recipient lifts it over the floor.
interface IAeroRootEmissionsHandler {
    function LEAF_VOTER() external view returns (address);
    function pendingRedeems(address recipient) external view returns (uint256);
}
