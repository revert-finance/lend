// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AeroGaugeFixture} from "../../../mocks/AeroGaugeFixture.sol";

/// @dev Deferring Aero gauge double for the vault integration suites; the knobs live on AeroGaugeFixture.
contract MockGauge is AeroGaugeFixture {
    constructor(address rewardToken, address npm, address pool_) AeroGaugeFixture(npm, pool_, rewardToken) {}
}
