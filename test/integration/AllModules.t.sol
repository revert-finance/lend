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

        vm.prank(TEST_NFT_3_ACCOUNT);
        vm.expectRevert(NFTHolder.ModuleBlocked.selector);
        NPM.safeTransferFrom(TEST_NFT_3_ACCOUNT, address(holder), TEST_NFT_3, abi.encode(params));
    }

    function testCompleteExample() external {
           
        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](3);
        params[0] = NFTHolder.ModuleParams(compoundorModuleIndex, "");
        params[1] = NFTHolder.ModuleParams(stopLossLimitModuleIndex, abi.encode(StopLossLimitModule.PositionConfig(false, false, false, 0, 0, -800000, 800000)));
        params[2] = NFTHolder.ModuleParams(collateralModuleIndex, abi.encode(CollateralModule.PositionConfigParams(true)));

        // add NFTs
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(holder), TEST_NFT, abi.encode(params));
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_2_ACCOUNT, address(holder), TEST_NFT_2, abi.encode(params));
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_2_ACCOUNT, address(holder), TEST_NFT_2_A, abi.encode(params));
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_2_ACCOUNT, address(holder), TEST_NFT_2_B, abi.encode(params));
        vm.prank(TEST_NFT_3_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_3_ACCOUNT, address(holder), TEST_NFT_3, abi.encode(params));
        vm.prank(TEST_NFT_4_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_4_ACCOUNT, address(holder), TEST_NFT_4, abi.encode(params));
        vm.prank(TEST_NFT_5_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_5_ACCOUNT, address(holder), TEST_NFT_5, abi.encode(params));

        // test simple autocompound without swap with other active modules
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT, CompoundorModule.RewardConversion.NONE, false, false));

        // reverting autocompound case - all compoundable tokens were lent out because out of range and lendable - so nothing to compound
        vm.expectRevert();
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_2, CompoundorModule.RewardConversion.NONE, false, false)); 

        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_2_A, CompoundorModule.RewardConversion.NONE, false, false)); 

        // reverting autocompound case - all compoundable tokens were lent out because out of range and lendable - so nothing to compound
        vm.expectRevert();
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_2_B, CompoundorModule.RewardConversion.NONE, false, false)); 

        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_3, CompoundorModule.RewardConversion.NONE, false, false));
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_4, CompoundorModule.RewardConversion.NONE, false, false));
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_5, CompoundorModule.RewardConversion.NONE, false, false));

        // withdraw NFTs
        vm.prank(TEST_NFT_ACCOUNT);
        holder.withdrawToken(TEST_NFT, TEST_NFT_ACCOUNT, "");

        // withdrawing collateral one by one for TEST_NFT_2_ACCOUNT (lent and unlent positions)
        uint liquidity;
        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 557475755488254604735);

        vm.prank(TEST_NFT_2_ACCOUNT);
        holder.withdrawToken(TEST_NFT_2, TEST_NFT_2_ACCOUNT, "");
        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 16746124600675462387);

        vm.prank(TEST_NFT_2_ACCOUNT);
        holder.withdrawToken(TEST_NFT_2_A, TEST_NFT_2_ACCOUNT, "");
        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 11859265196055707387);

        // unlend by owner
        vm.prank(TEST_NFT_2_ACCOUNT);
        collateralModule.unlend(TEST_NFT_2_B);

        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 11859265196055098557);

        // before removing execute stop loss while collateral
        vm.prank(TEST_NFT_2_ACCOUNT);
        holder.addTokenToModule(TEST_NFT_2_B, NFTHolder.ModuleParams(stopLossLimitModuleIndex, abi.encode(StopLossLimitModule.PositionConfig(true, true, true, type(uint64).max, type(uint64).max, 192179, 193380))));
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2_B, ""));

        // all was removed by stop loss module - so 0 liquidity left
        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 0);

        vm.prank(TEST_NFT_2_ACCOUNT);
        holder.withdrawToken(TEST_NFT_2_B, TEST_NFT_2_ACCOUNT, "");

        vm.prank(TEST_NFT_3_ACCOUNT);
        holder.withdrawToken(TEST_NFT_3, TEST_NFT_3_ACCOUNT, "");
        vm.prank(TEST_NFT_4_ACCOUNT);
        holder.withdrawToken(TEST_NFT_4, TEST_NFT_4_ACCOUNT, "");
        vm.prank(TEST_NFT_5_ACCOUNT);
        holder.withdrawToken(TEST_NFT_5, TEST_NFT_5_ACCOUNT, "");
    }
}
