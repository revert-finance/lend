// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @dev Metadata fixtures for the direct leaf receipt-token delivery path.
contract LeafDeliveryFixture {
    address public immutable RECEIPT_TOKEN;
    address public immutable LEAF_VOTER;

    constructor(address token, address voter) {
        RECEIPT_TOKEN = token;
        LEAF_VOTER = voter;
    }
}

contract LeafVoterFixture {
    address public immutable RECEIPT_TOKEN;
    address public immutable EMISSIONS_HANDLER;

    constructor(address token) {
        RECEIPT_TOKEN = token;
        EMISSIONS_HANDLER = address(new LeafDeliveryFixture(token, address(this)));
    }
}

/// @dev Stands in for CLGaugeFactory's penalty/referral configuration; ABI-compatible with the upstream getters.
contract AeroGaugeFactoryFixture {
    uint256 public minStakeBlocks;
    uint256 public penaltyRate;
    address public referral;
    uint256 public referralShare;

    function setConfig(uint256 blocks_, uint256 penalty_, address referral_, uint256 share_) external {
        minStakeBlocks = blocks_;
        penaltyRate = penalty_;
        referral = referral_;
        referralShare = share_;
    }

    function effectivePenaltyConfig(address) external view returns (uint256, uint256) {
        return (minStakeBlocks, penaltyRate);
    }

    function referralConfig(address) external view returns (address, uint256) {
        return (referral, referralShare);
    }
}
