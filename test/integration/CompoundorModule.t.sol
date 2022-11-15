// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestBase.sol";

import "../../src/NFTHolder.sol";
import "../../src/modules/CompoundorModule.sol";

contract CompoundorModuleTest is Test, TestBase {
    NFTHolder holder;
    CompoundorModule module;
    uint256 mainnetFork;
    uint8 moduleIndex;

    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);

        holder = new NFTHolder(NPM);
        module = new CompoundorModule(holder);

        moduleIndex = holder.addModule(NFTHolder.Module(module, true, false));
    }

    // add position with fees to module
    function _setupPosition() internal {

        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, "");

        NPM.safeTransferFrom(TEST_NFT_WITH_FEES_ACCOUNT, address(holder), TEST_NFT_WITH_FEES, abi.encode(params));
    }

    function testCompoundWithoutSwap() external {

        _setupPosition();

        // simple autocompound without swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = module.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_WITH_FEES, CompoundorModule.RewardConversion.NONE, false, false));

        assertEq(reward0, 3558940960047741131);
        assertEq(reward1, 3025524);
        assertEq(compounded0, 355894096004774113433);
        assertEq(compounded1, 302552417);

    }

    function testCompoundWithoutSwapConversion0() external {

        _setupPosition();

        // simple autocompound without swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = module.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_WITH_FEES, CompoundorModule.RewardConversion.TOKEN_0, false, false));

        assertEq(reward0, 6448722518610786144);
        assertEq(reward1, 0);
        assertEq(compounded0, 348543693453641008210);
        assertEq(compounded1, 296303699);

    }

    function testCompoundWithoutSwapConversion1() external {

        _setupPosition();

        // simple autocompound without swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = module.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_WITH_FEES, CompoundorModule.RewardConversion.TOKEN_1, false, false));

        assertEq(reward0, 0);
        assertEq(reward1, 6715850);
        assertEq(compounded0, 363011977924869594276);
        assertEq(compounded1, 308603466);
    }

    function testCompoundWithSwapNoConversion() external {

        _setupPosition();

        // simple autocompound with swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = module.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_WITH_FEES, CompoundorModule.RewardConversion.NONE, false, true));

        assertEq(reward0, 3833141649374257591);
        assertEq(reward1, 3258628);
        assertEq(compounded0, 383314164937425759473);
        assertEq(compounded1, 325862760);
    }

    function testCompoundWithSwapConversion0() external {

        _setupPosition();

        // simple autocompound with swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = module.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_WITH_FEES, CompoundorModule.RewardConversion.TOKEN_0, false, true));

        assertEq(reward0, 6919282185125863149);
        assertEq(reward1, 0);
        assertEq(compounded0, 373976720127185194223);
        assertEq(compounded1, 317924825);
    }

    function testCompoundWithSwapConversion1() external {

        _setupPosition();

        // simple autocompound with swap
        (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) = module.autoCompound(CompoundorModule.AutoCompoundParams(TEST_NFT_WITH_FEES, CompoundorModule.RewardConversion.TOKEN_1, false, true));

        assertEq(reward0, 0);
        assertEq(reward1, 6965742);
        assertEq(compounded0, 376519398080354422508);
        assertEq(compounded1, 320086390);
    }
}