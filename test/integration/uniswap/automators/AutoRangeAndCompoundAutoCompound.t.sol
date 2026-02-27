// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AutomatorIntegrationTestBase.sol";

import "../../../../src/transformers/AutoRangeAndCompound.sol";
import "../../../../src/utils/Constants.sol";

contract AutoRangeAndCompoundAutoCompoundTest is AutomatorIntegrationTestBase {
    AutoRangeAndCompound autoRange;

    function setUp() external {
        _setupBase();
        autoRange = new AutoRangeAndCompound(NPM, OPERATOR_ACCOUNT, WITHDRAWER_ACCOUNT, 60, 100, UNIVERSAL_ROUTER, EX0x);
    }

    function _configTokenForAutoCompound(uint256 tokenId, address owner) internal {
        vm.prank(owner);
        autoRange.configToken(tokenId, address(0), AutoRangeAndCompound.PositionConfig(0, 0, 0, 0, 0, 0, false, true, 0, 0, 0, 0));
    }

    function _approveAndConfig(uint256 tokenId, address owner) internal {
        vm.prank(owner);
        NPM.approve(address(autoRange), tokenId);
        _configTokenForAutoCompound(tokenId, owner);
    }

    function testNoAccess() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        autoRange.autoCompound(AutoRangeAndCompound.AutoCompoundParams(TEST_NFT_2, false, 0, block.timestamp));
    }

    function testNoApprove() external {
        _configTokenForAutoCompound(TEST_NFT_2, TEST_NFT_2_ACCOUNT);

        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert("Not approved");
        autoRange.autoCompound(AutoRangeAndCompound.AutoCompoundParams(TEST_NFT_2, false, 0, block.timestamp));
    }

    function testCompoundNoSwap() external {
        _approveAndConfig(TEST_NFT_2, TEST_NFT_2_ACCOUNT);

        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(TEST_NFT_2);

        vm.prank(OPERATOR_ACCOUNT);
        autoRange.autoCompound(AutoRangeAndCompound.AutoCompoundParams(TEST_NFT_2, false, 0, block.timestamp));

        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(TEST_NFT_2);
        assertGt(liquidityAfter, liquidityBefore);
    }

    function testCompoundSwap0To1() external {
        _approveAndConfig(TEST_NFT_2, TEST_NFT_2_ACCOUNT);

        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(TEST_NFT_2);

        vm.prank(OPERATOR_ACCOUNT);
        autoRange.autoCompound(AutoRangeAndCompound.AutoCompoundParams(TEST_NFT_2, true, 123456789012345678, block.timestamp));

        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(TEST_NFT_2);
        assertGt(liquidityAfter, liquidityBefore);
    }

    function testCompoundSwap1To0() external {
        _approveAndConfig(TEST_NFT_2, TEST_NFT_2_ACCOUNT);

        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(TEST_NFT_2);

        vm.prank(OPERATOR_ACCOUNT);
        autoRange.autoCompound(AutoRangeAndCompound.AutoCompoundParams(TEST_NFT_2, false, 1234567890123456, block.timestamp));

        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(TEST_NFT_2);
        assertGt(liquidityAfter, liquidityBefore);
    }

    function testSetAutoCompoundReward() external {
        uint64 currentReward = autoRange.totalRewardX64();

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRange.setAutoCompoundReward(currentReward + 1);

        autoRange.setAutoCompoundReward(currentReward - 1);
        assertEq(autoRange.totalRewardX64(), currentReward - 1);
    }
}
