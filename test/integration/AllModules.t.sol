// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract AllModulesTest is TestBase {

    uint8 moduleIndex1;
    uint8 moduleIndex2;
    uint8 moduleIndex3;
    uint8 moduleIndex4;

    function setUp() external {
        _setupBase();
        moduleIndex1 = _setupCompoundorModule();
        moduleIndex2 = _setupStopLossLimitModule();
        moduleIndex3 = _setupLockModule();
        moduleIndex4 = _setupCollateralModule();
    }
}
