// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/Contract.sol";

contract ContractTest is Test, BasicTestSetup {

    Contract c;

    function setUp() public {
        c = new Contract();
    }

    function testExample() public {
        uint160 lower = c.getSqrtRatioAtTick(-887272);
        uint160 middle = c.getSqrtRatioAtTick(0);
        uint160 upper = c.getSqrtRatioAtTick(887272);
    }
}
