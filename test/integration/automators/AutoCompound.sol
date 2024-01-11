// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IntegrationTestBase.sol";

import "../../../src/transformers/AutoCompound.sol";

contract AutoCompoundTest is IntegrationTestBase {
    
    AutoCompound autoCompound;

    function setUp() external {
        _setupBase();
        autoCompound = new AutoCompound(NPM, OPERATOR_ACCOUNT, WITHDRAWER_ACCOUNT, 60, 100);
    }

    function testCompoundNoSwap() external {

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.approve(address(autoCompound), TEST_NFT_2);

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_2);
        assertEq(liquidity, 80059851033970806503);

        vm.prank(OPERATOR_ACCOUNT);
        autoCompound.execute(AutoCompound.ExecuteParams(TEST_NFT_2, false, 0));

        (, , , , , , , liquidity, , , , ) = NPM.positions(TEST_NFT_2);
        assertEq(liquidity, 99102324844935209920);
    }

    function testCompoundSwap0To1() external {

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.approve(address(autoCompound), TEST_NFT_2);

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_2);
        assertEq(liquidity, 80059851033970806503);

        vm.prank(OPERATOR_ACCOUNT);
        autoCompound.execute(AutoCompound.ExecuteParams(TEST_NFT_2, true, 123456789012345678));

        // more liquidity than without swap
        (, , , , , , , liquidity, , , , ) = NPM.positions(TEST_NFT_2);
        assertEq(liquidity, 99117944276318382811);
    }

    function testCompoundSwap1To0() external {

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.approve(address(autoCompound), TEST_NFT_2);

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_2);
        assertEq(liquidity, 80059851033970806503);

        vm.prank(OPERATOR_ACCOUNT);
        autoCompound.execute(AutoCompound.ExecuteParams(TEST_NFT_2, false, 1234567890123456));

        // less liquidity than without swap
        (, , , , , , , liquidity, , , , ) = NPM.positions(TEST_NFT_2);
        assertEq(liquidity, 98864783327532224693);
    }
}
