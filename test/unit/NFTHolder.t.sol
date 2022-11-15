// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "./../../src/NFTHolder.sol";

import "./mock/WETH9.sol";
import "./mock/TestModule.sol";
import "./mock/TestNFT.sol";

contract NFTHolderTest is Test, IERC721Receiver {

    // copy-pasted events from NFTHolder - needed to be testable
    event AddedModule(uint8 index, IModule implementation);
    event SetModuleActive(uint8 index, bool isActive);

    TestNFT testNFT;
    NFTHolder holder;
    WETH9 weth9;
    uint tokenId;
    TestModule module1;
    TestModule module2;
    uint24 fee;
    INonfungiblePositionManager nonfungiblePositionManager;

    function setUp() public {
        weth9 = new WETH9();

        testNFT = new TestNFT();
        
        // unfortunately the uniswap factory / pools / npm are not in a state to be included in this test directly - versioning problems 
        // so needed calls are mocked instead

        // mock some needed calls
        vm.mockCall(address(testNFT), abi.encodeWithSelector(IPeripheryImmutableState.WETH9.selector), abi.encode(address(weth9)));
        vm.mockCall(address(testNFT), abi.encodeWithSelector(INonfungiblePositionManager.decreaseLiquidity.selector), abi.encode(0, 0));
        vm.mockCall(address(testNFT), abi.encodeWithSelector(INonfungiblePositionManager.collect.selector), abi.encode(0, 0));

        nonfungiblePositionManager = INonfungiblePositionManager(address(testNFT));

        holder = new NFTHolder(nonfungiblePositionManager);

        module1 = new TestModule(holder, true);
        module2 = new TestModule(holder, false);

        tokenId = testNFT.mint();
    }

    function testAddModule() external {

        vm.expectEmit(false, false, false, true);
        emit AddedModule(1, module1);

        holder.addModule(NFTHolder.Module(module1, true, false));

        vm.expectEmit(false, false, false, true);
        emit AddedModule(2, module2);

        holder.addModule(NFTHolder.Module(module2, true, false));
    }

    function testFailAddModuleZero() external {
        holder.addModule(NFTHolder.Module(IModule(address(0)), true, false));
    }

    function testFailAddModuleDuplicated() external {
        holder.addModule(NFTHolder.Module(module1, true, false));
        holder.addModule(NFTHolder.Module(module1, true, false));
    }

    function testSetModuleActive() external {
        holder.addModule(NFTHolder.Module(module1, false, false));

        vm.expectEmit(false, false, false, true);
        emit SetModuleActive(1, true);

        holder.setModuleActive(1, true);
    }

    function testFailSetInvalidModuleActive() external {
        holder.setModuleActive(0, true);
    }

    function testFailSetInvalidModuleActive2() external {
        holder.setModuleActive(2, true);
    }

    function testTransferTokenIn() external {

        uint balanceBefore = testNFT.balanceOf(address(holder));

        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, "");

        uint balanceAfter = testNFT.balanceOf(address(holder));

        assertEq(balanceAfter, balanceBefore + 1);

        assertEq(holder.tokenOwners(tokenId), address(this));
        assertEq(holder.tokenModules(tokenId), 0);
    }

    function testTransferTokenInWithApprove() external {

        uint balanceBefore = testNFT.balanceOf(address(holder));

        testNFT.approve(address(holder), tokenId);
        NFTHolder.ModuleParams[] memory initialModules;
        holder.addToken(tokenId, initialModules);

        uint balanceAfter = testNFT.balanceOf(address(holder));

        assertEq(balanceAfter, balanceBefore + 1);
    }

    function testTransferTokenInWithModules() external {

        uint8 moduleIndex = holder.addModule(NFTHolder.Module(module1, true, false));

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, "");
        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, abi.encode(params));
        assertEq(holder.tokenOwners(tokenId), address(this));
        assertEq(holder.tokenModules(tokenId), 1 << moduleIndex);
    }

    function testTransferTokenInWithModulesAndApprove() external {

        uint8 moduleIndex = holder.addModule(NFTHolder.Module(module1, true, false));
        uint8 moduleIndex2 = holder.addModule(NFTHolder.Module(module2, true, false));

        NFTHolder.ModuleParams[] memory initialModules = new NFTHolder.ModuleParams[](2);
        initialModules[0] = NFTHolder.ModuleParams(moduleIndex, "");
        initialModules[1] = NFTHolder.ModuleParams(moduleIndex2, "");

        testNFT.approve(address(holder), tokenId);       
        holder.addToken(tokenId, initialModules);

        assertEq(holder.tokenOwners(tokenId), address(this));
        assertEq(holder.tokenModules(tokenId), (1 << moduleIndex) + (1 << moduleIndex2));
    }

    function testSendOtherNFT() external {
        TestNFT otherNFT = new TestNFT();
        uint otherTokenId = otherNFT.mint();

        vm.expectRevert(NFTHolder.WrongNFT.selector);
        otherNFT.safeTransferFrom(address(this), address(holder), otherTokenId, "");
    }

    function testUnauthorizedWithdraw() external {
        vm.expectRevert(NFTHolder.Unauthorized.selector);
        holder.withdrawToken(123, address(this), "");
    }

    function testIllegalWithdraw() external {
        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, "");

        vm.expectRevert(NFTHolder.InvalidWithdrawTarget.selector);
        holder.withdrawToken(tokenId, address(holder), "");
    }

    function testAllModules() external {

        for (uint8 index = 0; index < 255; index++) {
            holder.addModule(NFTHolder.Module(new TestModule(holder, true), true, false));
        }

        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, "");

        holder.setModuleActive(1, true);
        holder.setModuleActive(255, true);

        assertEq(holder.tokenModules(tokenId), 0);

        holder.addTokenToModule(tokenId, NFTHolder.ModuleParams(1, ""));
        holder.addTokenToModule(tokenId, NFTHolder.ModuleParams(255, ""));

        assertEq(holder.tokenModules(tokenId), (1 << 1) + (1 << 255));

        holder.removeTokenFromModule(tokenId, 1);
        holder.removeTokenFromModule(tokenId, 255);

        assertEq(holder.tokenModules(tokenId), 0);
    }

    function testWithdraw() external {

        uint balanceBefore = testNFT.balanceOf(address(holder));

        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, "");

        uint balanceInbetween = testNFT.balanceOf(address(holder));

        holder.withdrawToken(tokenId, address(this), "");

        uint balanceAfter = testNFT.balanceOf(address(holder));

        assertEq(balanceInbetween, balanceBefore + 1);
        assertEq(balanceInbetween, balanceAfter + 1);
    }

    function testCollects() external {

        uint8 moduleIndex = holder.addModule(NFTHolder.Module(module1, true, false));
        uint8 module2Index = holder.addModule(NFTHolder.Module(module2, true, true));
        
        // register for first module
        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, "");
        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, abi.encode(params));

        // enabled module - ok
        module1.triggerCollectForTesting(tokenId);

        // not enabled module - nok
        vm.expectRevert(NFTHolder.Unauthorized.selector);
        module2.triggerCollectForTesting(tokenId);

        // owner - ok
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, address(this)));

        // other account - nok
        vm.expectRevert(NFTHolder.Unauthorized.selector);
        vm.prank(address(holder)); // dummy account
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, address(this)));

        // register for module which blocks withdrawals 
        holder.addTokenToModule(tokenId, NFTHolder.ModuleParams(module2Index, ""));

        // owner - nok anymore
        vm.expectRevert(TestModule.CheckCollectError.selector);
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, address(this)));

        // enabled module - nok anymore
        vm.expectRevert(TestModule.CheckCollectError.selector);
        module1.triggerCollectForTesting(tokenId);

        // blocking module - still ok (needs to do test in its own code)
        module2.triggerCollectForTesting(tokenId);

        // remove blocking module
        holder.removeTokenFromModule(tokenId, module2Index);

        // ok again
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, address(this)));
    }

    // for tests where NFTs are withdrawn
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
