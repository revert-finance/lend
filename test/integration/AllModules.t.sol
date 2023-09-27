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
        
        IHolder.ModuleParams[] memory params = new IHolder.ModuleParams[](4);
        params[0] = IHolder.ModuleParams(compoundorModuleIndex, "");
        params[1] = IHolder.ModuleParams(stopLossLimitModuleIndex, abi.encode(StopLossLimitModule.PositionConfig(false, false, false, -800000, 800000, 0, 0)));
        params[2] = IHolder.ModuleParams(lockModuleIndex, abi.encode(LockModule.PositionConfig(0)));
        params[3] = IHolder.ModuleParams(collateralModuleIndex, "");

        vm.prank(TEST_NFT_3_ACCOUNT);
        vm.expectRevert(Holder.ModuleBlocked.selector);
        NPM.safeTransferFrom(TEST_NFT_3_ACCOUNT, address(holder), TEST_NFT_3, abi.encode(params));
    }

    function testDirectAddAndThenModule() external {

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(compoundorModule), TEST_NFT);

        vm.expectRevert(CompoundorModule.NotConfigured.selector);
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT, false, false));

        vm.prank(TEST_NFT_ACCOUNT);
        compoundorModule.addTokenDirect(TEST_NFT, true);

        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT, false, false));

        IHolder.ModuleParams[] memory params = new IHolder.ModuleParams[](1);
        params[0] = IHolder.ModuleParams(collateralModuleIndex, "");

        // add NFTs to another module
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(holder), TEST_NFT, abi.encode(params));

        // because module is not activated in holder - it doesnt work anymore (although it is configured)
        vm.expectRevert(Module.Unauthorized.selector);
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT, false, false));

        // adding it to the module (again)
        vm.prank(TEST_NFT_ACCOUNT);
        holder.addTokenToModule(TEST_NFT, IHolder.ModuleParams(compoundorModuleIndex, ""));

        // works again
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT, false, false));

        // removing from module - deactivates it
        vm.prank(TEST_NFT_ACCOUNT);
        holder.removeTokenFromModule(TEST_NFT, compoundorModuleIndex);

        vm.expectRevert(CompoundorModule.NotConfigured.selector);
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT, false, false));

        // removing it from holder
        vm.prank(TEST_NFT_ACCOUNT);
        holder.withdrawToken(TEST_NFT, TEST_NFT_ACCOUNT, "");

        vm.expectRevert(CompoundorModule.NotConfigured.selector);
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT, false, false));
    }

    function testV3UtilsTransform() external {

        // add position to holder and module
        IHolder.ModuleParams[] memory params = new IHolder.ModuleParams[](1);
        params[0] = IHolder.ModuleParams(compoundorModuleIndex, "");
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_2_ACCOUNT, address(holder), TEST_NFT_2, abi.encode(params));

        // do withdraw of all fees
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(0),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            type(uint128).max,
            type(uint128).max,
            0,
            0,
            0,
            0,
            0,
            0,
            block.timestamp,
            TEST_NFT_2_ACCOUNT,
            TEST_NFT_2_ACCOUNT,
            false,
            "",
            ""
        );

        uint daiBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint wethBefore = WETH_ERC20.balanceOf(TEST_NFT_2_ACCOUNT);

        // transform with v3utils collecting fees
        vm.prank(TEST_NFT_2_ACCOUNT);
        holder.v3UtilsTransform(TEST_NFT_2, abi.encode(inst));

        // all fees collected to correct account
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - daiBefore, 311677619940061890346);
        assertEq(WETH_ERC20.balanceOf(TEST_NFT_2_ACCOUNT) - wethBefore, 98968916981575345);
    }

    function testCompleteExample() external {
           
        IHolder.ModuleParams[] memory params = new IHolder.ModuleParams[](3);
        params[0] = IHolder.ModuleParams(compoundorModuleIndex, "");
        params[1] = IHolder.ModuleParams(stopLossLimitModuleIndex, abi.encode(StopLossLimitModule.PositionConfig(false, false, false, -800000, 800000, 0, 0)));
        params[2] = IHolder.ModuleParams(collateralModuleIndex, "");

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
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT, false, false));
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_2, false, false)); 
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_2_A, false, false)); 
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_2_B, false, false)); 
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_3, false, false));
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_4, false, false));
        compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_5, false, false));

        // withdraw NFTs
        vm.prank(TEST_NFT_ACCOUNT);
        holder.withdrawToken(TEST_NFT, TEST_NFT_ACCOUNT, "");

        // withdrawing collateral one by one for TEST_NFT_2_ACCOUNT (lent and unlent positions)
        uint liquidity;
        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 396930312569658899933);

        vm.prank(TEST_NFT_2_ACCOUNT);
        holder.withdrawToken(TEST_NFT_2, TEST_NFT_2_ACCOUNT, "");
        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 13593085210818182898);

        vm.prank(TEST_NFT_2_ACCOUNT);
        holder.withdrawToken(TEST_NFT_2_A, TEST_NFT_2_ACCOUNT, "");
        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 8706225806198427898);

        (,liquidity,) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(liquidity, 8706225806198427898);

        // before removing execute stop loss while collateral
        vm.prank(TEST_NFT_2_ACCOUNT);
        holder.addTokenToModule(TEST_NFT_2_B, IHolder.ModuleParams(stopLossLimitModuleIndex, abi.encode(StopLossLimitModule.PositionConfig(true, false, false, 192179, 193380, type(uint64).max, type(uint64).max))));

        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2_B, "", block.timestamp));

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
