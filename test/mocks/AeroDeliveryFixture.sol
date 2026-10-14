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
