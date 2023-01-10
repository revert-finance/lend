// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract AllModulesTest is TestBase {
    uint8 compoundorModuleIndex;
    uint8 stopLossLimitModuleIndex;
    uint8 lockModuleIndex;
    uint8 collateralModuleIndex;

    function setUp() external {
        _setupBase();

        // setup real configuration with locking
        compoundorModuleIndex = _setupCompoundorModule(0);
        assertEq(compoundorModuleIndex, 1);
        stopLossLimitModuleIndex = _setupStopLossLimitModule(0);
        assertEq(stopLossLimitModuleIndex, 2);
        lockModuleIndex = _setupLockModule(0);
        assertEq(lockModuleIndex, 3);
        collateralModuleIndex = _setupCollateralModule(1 << lockModuleIndex);
        assertEq(collateralModuleIndex, 4);

        // update blocking config for existing module after new incompatible module is added
        holder.setModuleBlocking(lockModuleIndex, 1 << collateralModuleIndex);
    }

    function testBlocked() external {
        
        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](4);
        params[0] = NFTHolder.ModuleParams(compoundorModuleIndex, "");
        params[1] = NFTHolder.ModuleParams(stopLossLimitModuleIndex, abi.encode(StopLossLimitModule.PositionConfig(false, false, false, 0, 0, -800000, 800000)));
        params[2] = NFTHolder.ModuleParams(lockModuleIndex, abi.encode(LockModule.PositionConfig(0)));
        params[3] = NFTHolder.ModuleParams(collateralModuleIndex, abi.encode(CollateralModule.PositionConfigParams(false)));

        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);
        vm.expectRevert(NFTHolder.ModuleBlocked.selector);
        NPM.safeTransferFrom(TEST_NFT_WITH_FEES_ACCOUNT, address(holder), TEST_NFT_WITH_FEES, abi.encode(params));
    }

    function testCompleteExample() external {
           
        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](3);
        params[0] = NFTHolder.ModuleParams(compoundorModuleIndex, "");
        params[1] = NFTHolder.ModuleParams(stopLossLimitModuleIndex, abi.encode(StopLossLimitModule.PositionConfig(false, false, false, 0, 0, -800000, 800000)));
        params[2] = NFTHolder.ModuleParams(collateralModuleIndex, abi.encode(CollateralModule.PositionConfigParams(true)));

        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_WITH_FEES_ACCOUNT, address(holder), TEST_NFT_WITH_FEES, abi.encode(params));

        // test simple autocompound without swap with other active modules
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_WITH_FEES, CompoundorModule.RewardConversion.NONE, false, false));

        assertEq(reward0, 3558940960047741131);
        assertEq(reward1, 3025524);
        assertEq(compounded0, 355894096004774113433);
        assertEq(compounded1, 302552417);

        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);
        holder.withdrawToken(TEST_NFT_WITH_FEES, TEST_NFT_WITH_FEES_ACCOUNT, "");
    }


}
