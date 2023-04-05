// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "./../../src/Holder.sol";

import "./mock/WETH9.sol";
import "./mock/TestModule.sol";
import "./mock/TestNFT.sol";
import "./mock/TestFlashTransform.sol";

contract HolderUnitTest is Test, IERC721Receiver {

    // copy-pasted events from Holder - needed to be testable
    event AddedModule(uint8 index, IModule implementation);
    event SetModuleBlocking(uint8 index, uint blocking);

    TestNFT testNFT;
    Holder holder;
    WETH9 weth9;
    uint tokenId;
    TestModule module1;
    TestModule module2;
    uint24 fee;
    INonfungiblePositionManager nonfungiblePositionManager;
    TestFlashTransform testFlashTransform;

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

        holder = new Holder(nonfungiblePositionManager);

        module1 = new TestModule(holder, true);
        module2 = new TestModule(holder, false);

        tokenId = testNFT.mint();

        // set up flash transform contract
        testFlashTransform = new TestFlashTransform(nonfungiblePositionManager);
        holder.setFlashTransformContract(address(testFlashTransform));
    }

    function testAddModule() external {

        vm.expectEmit(false, false, false, true);
        emit AddedModule(1, module1);

        holder.addModule(module1, 0);

        vm.expectEmit(false, false, false, true);
        emit AddedModule(2, module2);

        holder.addModule(module2, 0);
    }

    function testFailAddModuleZero() external {
        holder.addModule(IModule(address(0)), 0);
    }

    function testFailAddModuleDuplicated() external {
        holder.addModule(module1, 0);
        holder.addModule(module1, 0);
    }

    function testSetModuleBlocking() external {
        holder.addModule(module1, 0);

        vm.expectEmit(false, false, false, true);
        emit SetModuleBlocking(1, 0);

        holder.setModuleBlocking(1, 0);
    }

    function testFailSetInvalidModuleBlocking() external {
        holder.setModuleBlocking(0, 0);
    }

    function testFailSetInvalidModuleBlocking2() external {
        holder.setModuleBlocking(2, 0);
    }

    function testBlockedModules() external {
        // blocked module
        uint8 moduleIndex = holder.addModule(module1, 0);
        holder.setModuleBlocking(moduleIndex, (1 << moduleIndex));

        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, "");

        // can't add to blocked module
        vm.expectRevert(Holder.ModuleBlocked.selector);
        holder.addTokenToModule(tokenId, IHolder.ModuleParams(moduleIndex, ""));

        holder.setModuleBlocking(moduleIndex, 0);
        holder.addTokenToModule(tokenId, IHolder.ModuleParams(moduleIndex, ""));

        uint8 module2Index = holder.addModule(module2, (1 << moduleIndex));

        // can't add to module blocked by other active module
        vm.expectRevert(Holder.ModuleBlocked.selector);
        holder.addTokenToModule(tokenId, IHolder.ModuleParams(module2Index, ""));

        // remove from blocking module
        holder.removeTokenFromModule(tokenId, moduleIndex);

        // now can be added to new module
        holder.addTokenToModule(tokenId, IHolder.ModuleParams(module2Index, ""));
    }

    function testMaxNfts() external {

        // add allowed
        for (uint index = 0; index < holder.MAX_TOKENS_PER_ADDRESS(); index++) {
            uint id = testNFT.mint();
            nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), id, "");
        }

        uint id = testNFT.mint();

        // can't add one more
        vm.expectRevert(Holder.MaxTokensReached.selector);
        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), id, "");
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
        IHolder.ModuleParams[] memory initialModules;
        holder.addToken(tokenId, initialModules);

        uint balanceAfter = testNFT.balanceOf(address(holder));

        assertEq(balanceAfter, balanceBefore + 1);
    }

    function testTransferTokenInWithModules() external {

        uint8 moduleIndex = holder.addModule(module1, 0);

        IHolder.ModuleParams[] memory params = new IHolder.ModuleParams[](1);
        params[0] = IHolder.ModuleParams(moduleIndex, "");
        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, abi.encode(params));
        assertEq(holder.tokenOwners(tokenId), address(this));
        assertEq(holder.tokenModules(tokenId), 1 << moduleIndex);
    }

    function testTransferTokenInWithModulesAndApprove() external {

        uint8 moduleIndex = holder.addModule(module1, 0);
        uint8 moduleIndex2 = holder.addModule(module2, 0);

        IHolder.ModuleParams[] memory initialModules = new IHolder.ModuleParams[](2);
        initialModules[0] = IHolder.ModuleParams(moduleIndex, "");
        initialModules[1] = IHolder.ModuleParams(moduleIndex2, "");

        testNFT.approve(address(holder), tokenId);       
        holder.addToken(tokenId, initialModules);

        assertEq(holder.tokenOwners(tokenId), address(this));
        assertEq(holder.tokenModules(tokenId), (1 << moduleIndex) + (1 << moduleIndex2));
    }

    function testSendOtherNFT() external {
        TestNFT otherNFT = new TestNFT();
        uint otherTokenId = otherNFT.mint();

        vm.expectRevert(Holder.WrongContract.selector);
        otherNFT.safeTransferFrom(address(this), address(holder), otherTokenId, "");
    }

    function testUnauthorizedWithdraw() external {
        vm.expectRevert(Holder.Unauthorized.selector);
        holder.withdrawToken(123, address(this), "");
    }

    function testIllegalWithdraw() external {
        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, "");

        vm.expectRevert(Holder.InvalidWithdrawTarget.selector);
        holder.withdrawToken(tokenId, address(holder), "");
    }

    function testAllModules() external {

        for (uint8 index = 0; index < 255; index++) {
            holder.addModule(new TestModule(holder, true), 0);
        }

        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, "");

        holder.setModuleBlocking(1, 0);
        holder.setModuleBlocking(255, 0);

        assertEq(holder.tokenModules(tokenId), 0);

        holder.addTokenToModule(tokenId, IHolder.ModuleParams(1, ""));
        holder.addTokenToModule(tokenId, IHolder.ModuleParams(255, ""));

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

        uint8 moduleIndex = holder.addModule(module1, 0);
        uint8 module2Index = holder.addModule(module2, 0);
        
        // register for first module
        IHolder.ModuleParams[] memory params = new IHolder.ModuleParams[](1);
        params[0] = IHolder.ModuleParams(moduleIndex, "");
        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, abi.encode(params));

        // enabled module - ok
        module1.triggerCollectForTesting(tokenId);

        // not enabled module - nok
        vm.expectRevert(Holder.Unauthorized.selector);
        module2.triggerCollectForTesting(tokenId);

        // owner - ok
        holder.decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, false, address(this), ""));

        // other account - nok
        vm.expectRevert(Holder.Unauthorized.selector);
        vm.prank(address(holder)); // dummy account
        holder.decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, false, address(this), ""));

        // register for module which blocks withdrawals 
        holder.addTokenToModule(tokenId, IHolder.ModuleParams(module2Index, ""));

        // owner - nok anymore
        vm.expectRevert(TestModule.CheckCollectError.selector);
        holder.decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, false, address(this), ""));

        // enabled module - nok anymore
        vm.expectRevert(TestModule.CheckCollectError.selector);
        module1.triggerCollectForTesting(tokenId);

        // blocking module - still ok (needs to do test in its own code)
        module2.triggerCollectForTesting(tokenId);

        // remove blocking module
        holder.removeTokenFromModule(tokenId, module2Index);

        // ok again
        holder.decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, false, address(this), ""));
    }

    function testTransform() external {
        nonfungiblePositionManager.safeTransferFrom(address(this), address(holder), tokenId, "");

        uint balanceBefore = testNFT.balanceOf(address(holder));

        // send token to external contract for manipulation and return in the same call
        holder.flashTransform(tokenId, "");

        uint balanceAfter = testNFT.balanceOf(address(holder));

        assertEq(balanceBefore, balanceAfter);
    }

    // for tests where NFTs are withdrawn
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
