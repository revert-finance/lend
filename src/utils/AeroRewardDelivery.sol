// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../interfaces/aero/IAeroGauge.sol";

/// @dev Shared by registration and deploy preflight. Dependencies remain owner-selected and trusted.
library AeroRewardDelivery {
    error UnsupportedRewardDelivery();

    /// @return rootHandler Zero for direct leaf receipts; otherwise the synchronous local root handler.
    function validate(address gauge, address rewardToken) internal view returns (address rootHandler) {
        address voter = IAeroGauge(gauge).voter();
        IAeroLeafVoter leaf = IAeroLeafVoter(voter);
        address handler = leaf.EMISSIONS_HANDLER();
        if (IAeroLeafEmissionsHandler(handler).LEAF_VOTER() != voter) revert UnsupportedRewardDelivery();
        if (leaf.RECEIPT_TOKEN() == rewardToken) {
            if (IAeroLeafEmissionsHandler(handler).RECEIPT_TOKEN() != rewardToken) revert UnsupportedRewardDelivery();
            return address(0);
        }

        // Root rewards must settle locally and atomically into the configured AERO token, not bridge elsewhere.
        address orchestrator;
        try IAeroSettlementVoter(voter).ORCHESTRATOR() returns (address value) {
            orchestrator = value;
        } catch {
            revert UnsupportedRewardDelivery();
        }
        IAeroRootLocalAdapter adapter = IAeroRootLocalAdapter(IAeroLeafOrchestrator(orchestrator).adapter());
        address rootOrchestrator = adapter.ROOT_MESSAGE_ORCHESTRATOR();
        address rootVoter = IAeroRootOrchestrator(rootOrchestrator).VOTER();
        if (
            IAeroLeafOrchestrator(orchestrator).ROOT_CHAIN_ID() != block.chainid
                || adapter.REMOTE_CHAIN_ID() != block.chainid || adapter.LEAF_MESSAGE_ORCHESTRATOR() != orchestrator
                || IAeroSettlementVoter(rootVoter).ORCHESTRATOR() != rootOrchestrator
                || IAeroSettlementVoter(rootVoter).TOKEN() != rewardToken
        ) revert UnsupportedRewardDelivery();
        IAeroRootEmissionsHandler(handler).pendingRedeems(address(this));
        return handler;
    }
}
