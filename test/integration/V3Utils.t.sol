// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../BaseTest.sol";
import "../../src/V3Utils.sol";

contract V3UtilsIntegrationTest is Test, BaseTest {

    V3Utils c;
    uint256 mainnetFork;

    address constant TEST_ACCOUNT = 0xc00d8dAC46b1F8bcEae2477591822B4E5B0a7C6b;
    uint constant TEST_NFT_ID = 302847;
    bytes constant SWAP_DATA = hex"e449022e00000000000000000000000000000000000000000000000000000000000e5e2900000000000000000000000000000000000000000000000005ecb1c3f54026a9000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000003d0acd52ee4a9271a0ffe75f9b91049152bac64bcfee7c08";

    function setUp() public {
        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15483331);
        vm.selectFork(mainnetFork);
        c = new V3Utils(WETH, FACTORY, NPM, SWAP, 10 ** 16, msg.sender);
    }

    function testWithNoAction() external {
        assertEq(NPM.ownerOf(TEST_NFT_ID), TEST_ACCOUNT);
        V3Utils.Instructions memory inst = _getInstructions(V3Utils.WhatToDo.NOTHING);
        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
        assertEq(NPM.ownerOf(TEST_NFT_ID), TEST_ACCOUNT);
    }

    function testWithChangeRange() external {
        assertEq(NPM.ownerOf(TEST_NFT_ID), TEST_ACCOUNT);
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_SWAP,
            address(USDC),
            100000,
            SWAP_DATA,
            100000,
            SWAP_DATA,
            0,
            0,
            0,
            false,
            block.timestamp+100,
            ""
        );
        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
        assertEq(NPM.ownerOf(TEST_NFT_ID), TEST_ACCOUNT);
    }





    function _getInstructions(V3Utils.WhatToDo whatToDo) internal returns (V3Utils.Instructions memory inst) {
        return V3Utils.Instructions(
            whatToDo,
            address(0),
            0,
            "",
            0,
            "",
            0,
            0,
            0,
            false,
            0,
            ""
        );
    }
}
