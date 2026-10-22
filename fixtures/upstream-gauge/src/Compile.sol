// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

// Compile the pinned, unmodified upstream implementation separately from Lend's 0.8.24 sources.
import {CLGauge} from "contracts/gauge/CLGauge.sol";
import {NonfungiblePositionManager} from "contracts/periphery/NonfungiblePositionManager.sol";
