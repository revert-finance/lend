// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./VerifyDeployment.s.sol";

contract VerifyDeploymentArbitrum is VerifyDeployment {
    function run() external override {
        runArbitrum();
    }
} 