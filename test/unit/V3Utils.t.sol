// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../TestBase.sol";
import "../../src/V3Utils.sol";

// unit tests with mocked external calls
contract V3UtilsTest is Test, TestBase {

    V3Utils c;

    function setUp() public {
        c = new V3Utils(WETH, FACTORY, NPM, 10 ** 16, msg.sender);
    }

    function testSwapAndMint() external {
        //TODO mocking hell
    }

    function testSwapAndIncrease() external {
        //TODO mocking hell
    }
}
