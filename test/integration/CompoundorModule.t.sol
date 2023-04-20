// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract CompoundorModuleTest is TestBase {
    uint8 moduleIndex;

    function setUp() external {
        _setupBase();
        moduleIndex = _setupCompoundorModule(0);
    }

    // add position with fees to compoundorModule
    function _setupPosition() internal {

        vm.prank(TEST_NFT_3_ACCOUNT);

        IHolder.ModuleParams[] memory params = new IHolder.ModuleParams[](1);
        params[0] = IHolder.ModuleParams(moduleIndex, "");

        NPM.safeTransferFrom(TEST_NFT_3_ACCOUNT, address(holder), TEST_NFT_3, abi.encode(params));
    }

    function testCompoundWithoutSwap() external {

        _setupPosition();

        // simple autocompound without swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_3, CompoundorModule.RewardConversion.NONE, false, false));

        assertEq(reward0, 3558940960047741131);
        assertEq(reward1, 3025524);
        assertEq(compounded0, 355894096004774113433);
        assertEq(compounded1, 302552417);

    }

    function testCompoundWithoutSwapConversion0() external {

        _setupPosition();

        // simple autocompound without swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_3, CompoundorModule.RewardConversion.TOKEN_0, false, false));

        assertEq(reward0, 6448722518610786144);
        assertEq(reward1, 0);
        assertEq(compounded0, 348543693453641008210);
        assertEq(compounded1, 296303699);

    }

    function testCompoundWithoutSwapConversion1() external {

        _setupPosition();

        // simple autocompound without swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_3, CompoundorModule.RewardConversion.TOKEN_1, false, false));

        assertEq(reward0, 0);
        assertEq(reward1, 6715850);
        assertEq(compounded0, 363011977924869594276);
        assertEq(compounded1, 308603466);
    }

    function testCompoundWithSwapNoConversion() external {

        _setupPosition();

        // simple autocompound with swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_3, CompoundorModule.RewardConversion.NONE, false, true));

        assertEq(reward0, 3833141649374257591);
        assertEq(reward1, 3258628);
        assertEq(compounded0, 383314164937425759473);
        assertEq(compounded1, 325862760);
    }

    function testCompoundWithSwapConversion0() external {

        _setupPosition();

        // simple autocompound with swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_3, CompoundorModule.RewardConversion.TOKEN_0, false, true));

        assertEq(reward0, 6919282185125863149);
        assertEq(reward1, 0);
        assertEq(compounded0, 373976720127185194223);
        assertEq(compounded1, 317924825);
    }

    function testCompoundWithSwapConversion1() external {

        _setupPosition();

        // simple autocompound with swap
        vm.prank(WHALE_ACCOUNT);
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = compoundorModule.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_3, CompoundorModule.RewardConversion.TOKEN_1, false, true));

        uint storedReward1 = compoundorModule.accountBalances(WHALE_ACCOUNT, address(USDC));

        assertEq(reward0, 0);
        assertEq(reward1, 6965742);
        assertEq(storedReward1, 6965742);
        assertEq(compounded0, 376519398080354422508);
        assertEq(compounded1, 320086390);

        uint balanceBefore = USDC.balanceOf(WHALE_ACCOUNT);

        // test getting fees partially
        vm.prank(WHALE_ACCOUNT);
        compoundorModule.withdrawBalance(address(USDC), WHALE_ACCOUNT, 1);
        assertEq(compoundorModule.accountBalances(WHALE_ACCOUNT, address(USDC)), storedReward1 - 1);
        assertEq(USDC.balanceOf(WHALE_ACCOUNT) - balanceBefore, 1);

        // test getting fees rest / all
        vm.prank(WHALE_ACCOUNT);
        compoundorModule.withdrawBalance(address(USDC), WHALE_ACCOUNT, 0);
        assertEq(compoundorModule.accountBalances(WHALE_ACCOUNT, address(USDC)), 0);
        assertEq(USDC.balanceOf(WHALE_ACCOUNT) - balanceBefore, storedReward1);
    }

    // mint directly to module
    function testInitiateAndAddToCompound() external {
        
        // instructions to add to compoundor compoundorModule
        IHolder.ModuleParams[] memory moduleParams = new IHolder.ModuleParams[](1);
        moduleParams[0] = IHolder.ModuleParams(moduleIndex, "");

        // add one sided position
        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI,
            USDC,
            500,
            -MIN_TICK_500 - 200000,
            -MIN_TICK_500,
            1 ether,
            0,
            WHALE_ACCOUNT,
            address(holder),
            block.timestamp,
            IERC20(address(0)),
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            true,
            abi.encode(moduleParams)
        );

        vm.prank(WHALE_ACCOUNT);
        DAI.approve(address(v3utils), 1 ether);

        vm.prank(WHALE_ACCOUNT);
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = v3utils.swapAndMint(params);

        assertEq(holder.balanceOf(WHALE_ACCOUNT), 1);
        assertEq(holder.tokenOwners(tokenId), WHALE_ACCOUNT);
        assertEq(holder.tokenModules(tokenId), 1 << moduleIndex);
    }
}