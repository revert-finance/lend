// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../script/DeployAeroV3UtilsMultichain.s.sol";
import "../../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";

/// @dev Run separately against each pinned target-chain fork. No live transactions.
contract AeroV3UtilsMultichainTest is Test {
    V3Utils utils;
    INonfungiblePositionManager npm;
    IAerodromeSlipstreamPool pool;
    address beneficiary = address(0x1234);
    address finalOwner = address(0x5678);
    address deployer = 0x83681C14770b44361e21Faf91D8325423365eA5C;

    function setUp() public {
        require(block.chainid == 1 || block.chainid == 4663, "Run on a target-chain fork");
        vm.setEnv("AERO_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("AERO_DEPLOYER", vm.toString(deployer));
        vm.setEnv("AERO_V3UTILS_OWNER", vm.toString(finalOwner));
        utils = (new DeployAeroV3UtilsMultichain()).run();
        npm = utils.nonfungiblePositionManager();
        pool = IAerodromeSlipstreamPool(
            block.chainid == 1
                ? address(0xd661623947EF2Ead12D577b47021C167d163B0c5)
                : address(0x7615926023bb149f36095645C2a81DC367d39750)
        );
    }

    function testRejectsWrongChainBeforeCreatingContract() public {
        vm.chainId(8453);
        DeployAeroV3UtilsMultichain script = new DeployAeroV3UtilsMultichain();
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert("Wrong chain");
        script.run();
        assertEq(vm.getNonce(deployer), nonce);
    }

    function testRejectsMismatchedFactoryBeforeCreatingContract() public {
        vm.mockCall(address(npm), abi.encodeWithSelector(npm.factory.selector), abi.encode(address(0xdead)));
        DeployAeroV3UtilsMultichain script = new DeployAeroV3UtilsMultichain();
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert("NPM factory mismatch");
        script.run();
        assertEq(vm.getNonce(deployer), nonce);
    }

    function testOwnershipRequiresAcceptanceByNominatedOwner() public {
        assertEq(utils.owner(), deployer);
        assertEq(utils.pendingOwner(), finalOwner);
        vm.prank(beneficiary);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        utils.acceptOwnership();
        vm.prank(finalOwner);
        utils.acceptOwnership();
        assertEq(utils.owner(), finalOwner);
        assertEq(utils.pendingOwner(), address(0));
    }

    function testMintAndFullWithdrawOnLiveAeroPool() public {
        address token0 = pool.token0();
        address token1 = pool.token1();
        address weth = address(utils.weth());
        uint256 amount0 = token0 == weth ? 0.01 ether : 100e6;
        uint256 amount1 = token1 == weth ? 0.01 ether : 100e6;
        // Fork-only fixture funding from a real token holder. Robinhood's USDG
        // balance implementation is not compatible with stdStorage-based deal().
        vm.startPrank(address(pool));
        assertTrue(IERC20(token0).transfer(beneficiary, amount0));
        assertTrue(IERC20(token1).transfer(beneficiary, amount1));
        vm.stopPrank();
        (, int24 tick,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        int24 center = tick - (((tick % spacing) + spacing) % spacing);
        V3Utils.SwapAndMintParams memory p;
        p.token0 = IERC20(token0);
        p.token1 = IERC20(token1);
        p.fee = uint24(spacing);
        p.tickLower = center - 20 * spacing;
        p.tickUpper = center + 20 * spacing;
        p.amount0 = amount0;
        p.amount1 = amount1;
        p.recipient = beneficiary;
        p.recipientNFT = beneficiary;
        p.deadline = block.timestamp;
        vm.startPrank(beneficiary);
        IERC20(token0).approve(address(utils), amount0);
        IERC20(token1).approve(address(utils), amount1);
        (uint256 tokenId, uint128 liquidity,,) = utils.swapAndMint(p);
        assertGt(liquidity, 0);
        assertEq(npm.ownerOf(tokenId), beneficiary);
        (,,,,, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        assertEq(lower, p.tickLower);
        assertEq(upper, p.tickUpper);
        V3Utils.Instructions memory instructions;
        instructions.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        instructions.liquidity = liquidity;
        instructions.feeAmount0 = type(uint128).max;
        instructions.feeAmount1 = type(uint128).max;
        instructions.deadline = block.timestamp;
        instructions.recipient = beneficiary;
        npm.approve(address(utils), tokenId);
        utils.execute(tokenId, instructions);
        vm.stopPrank();
        (,,,,,,, uint128 remaining,,,,) = npm.positions(tokenId);
        assertEq(remaining, 0);
        assertEq(npm.ownerOf(tokenId), beneficiary);
        assertGe(IERC20(token0).balanceOf(beneficiary), amount0 - 2);
        assertGe(IERC20(token1).balanceOf(beneficiary), amount1 - 2);
        assertEq(IERC20(token0).balanceOf(address(utils)), 0);
        assertEq(IERC20(token1).balanceOf(address(utils)), 0);
    }
}
