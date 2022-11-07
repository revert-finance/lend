// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestBase.sol";
import "./mock/WETH9.sol";
import "../../src/V3Utils.sol";

// unit tests with mocked external calls
contract V3UtilsTest is Test, TestBase {

    V3Utils c;

    function setUp() public {
        vm.mockCall(address(NPM), abi.encodeWithSelector(IPeripheryImmutableState.WETH9.selector), abi.encode(address(WETH_ERC20)));
        c = new V3Utils(NPM);
    }
}
