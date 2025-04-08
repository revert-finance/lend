// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AutomatorIntegrationTestBase.sol";

import "../../../src/automators/AutoExit.sol";
import "../../../src/utils/Constants.sol";

contract AutoExitTest is AutomatorIntegrationTestBase {
    AutoExit autoExit;

    function setUp() external {
        _setupBase();
        autoExit = new AutoExit(NPM, OPERATOR_ACCOUNT, WITHDRAWER_ACCOUNT, 60, 100, EX0x, UNIVERSAL_ROUTER);
    }

    function _setConfig(
        uint256 tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        bool onlyFees
    ) internal {
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig(
            isActive,
            token0Swap,
            token1Swap,
            token0TriggerTick,
            token1TriggerTick,
            token0SlippageX64,
            token1SlippageX64,
            onlyFees,
            onlyFees ? MAX_FEE_REWARD : MAX_REWARD
        );

        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(tokenId, config);
    }

    function testNoLiquidity() external {
        _setConfig(TEST_NFT, true, false, false, 0, 0, type(int24).min, type(int24).max, false);

        (,,,,,,, uint128 liquidity,,,,) = NPM.positions(TEST_NFT);

        assertEq(liquidity, 0);

        vm.expectRevert(Constants.NoLiquidity.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", 0, 0, block.timestamp, MAX_REWARD));
    }

    function _addLiquidity() internal returns (uint256 amount0, uint256 amount1) {
        // add onesided liquidity
        vm.startPrank(TEST_NFT_ACCOUNT);
        DAI.approve(address(NPM), 1000000000000000000);
        (, amount0, amount1) = NPM.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams(TEST_NFT, 1000000000000000000, 0, 0, 0, block.timestamp)
        );

        assertEq(amount0, 999999999999999633);
        assertEq(amount1, 0);

        vm.stopPrank();
    }

    struct SwapRangesState {
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
    }

    function testDirectSendNFT() external {
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(abi.encodePacked("ERC721: transfer to non ERC721Receiver implementer")); // NFT manager doesnt resend original error for some reason
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(autoExit), TEST_NFT);
    }

    function testSetTWAPSeconds() external {
        uint16 maxTWAPTickDifference = autoExit.maxTWAPTickDifference();
        autoExit.setTWAPConfig(maxTWAPTickDifference, 120);
        assertEq(autoExit.TWAPSeconds(), 120);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoExit.setTWAPConfig(maxTWAPTickDifference, 30);
    }

    function testSetMaxTWAPTickDifference() external {
        uint32 TWAPSeconds = autoExit.TWAPSeconds();
        autoExit.setTWAPConfig(5, TWAPSeconds);
        assertEq(autoExit.maxTWAPTickDifference(), 5);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoExit.setTWAPConfig(600, TWAPSeconds);
    }

    function testSetOperator() external {
        assertEq(autoExit.operators(TEST_NFT_ACCOUNT), false);
        autoExit.setOperator(TEST_NFT_ACCOUNT, true);
        assertEq(autoExit.operators(TEST_NFT_ACCOUNT), true);
    }

    function testUnauthorizedSetConfig() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(TEST_NFT_2, AutoExit.PositionConfig(false, false, false, 0, 0, 0, 0, false, MAX_REWARD));
    }

    function testResetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(TEST_NFT, AutoExit.PositionConfig(false, false, false, 0, 0, 0, 0, false, MAX_REWARD));
    }

    function testInvalidConfig() external {
        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(
            TEST_NFT, AutoExit.PositionConfig(true, false, false, 800000, -800000, 0, 0, false, MAX_REWARD)
        );
    }

    function testValidSetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        AutoExit.PositionConfig memory configIn =
            AutoExit.PositionConfig(true, false, false, -800000, 800000, 0, 0, false, MAX_REWARD);
        autoExit.configToken(TEST_NFT, configIn);
        (bool i1, bool i2, bool i3, int24 i4, int24 i5, uint64 i6, uint64 i7, bool i8, uint64 i9) =
            autoExit.positionConfigs(TEST_NFT);
        assertEq(abi.encode(configIn), abi.encode(AutoExit.PositionConfig(i1, i2, i3, i4, i5, i6, i7, i8, i9)));
    }

    function testNonOperator() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", 0, 0, block.timestamp, MAX_REWARD));
    }

    function testRunWithoutApprove() external {
        // out of range position
        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(
            TEST_NFT_2, AutoExit.PositionConfig(true, false, false, -84121, -78240, 0, 0, false, MAX_REWARD)
        );

        // fails when sending NFT
        vm.expectRevert(abi.encodePacked("Not approved"));
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, "", 0, 0, block.timestamp, MAX_REWARD));
    }

    function testRunWithoutConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(autoExit), true);

        vm.expectRevert(Constants.NotConfigured.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", 0, 0, block.timestamp, MAX_REWARD));
    }

    function testRunNotReady() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(autoExit), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(
            TEST_NFT_2_A, AutoExit.PositionConfig(true, false, false, -276331, -276320, 0, 0, false, MAX_REWARD)
        );

        // in range position cant be run
        vm.expectRevert(Constants.NotReady.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2_A, "", 0, 0, block.timestamp, MAX_REWARD));
    }

  

    // tests LimitOrder without adding to module
    function testLimitOrder(bool onlyFees) external {
        // using out of range position TEST_NFT_2
        // available amounts -> DAI (fees) 311677619940061890346 WETH(fees + liquidity) 506903060556612041

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(autoExit), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(
            TEST_NFT_2,
            AutoExit.PositionConfig(
                true,
                false,
                false,
                -84121,
                -78240,
                uint64(Q64 / 100),
                uint64(Q64 / 100),
                onlyFees,
                onlyFees ? MAX_FEE_REWARD : MAX_REWARD
            )
        ); // 1% max slippage

        uint256 contractWETHBalanceBefore = WETH_ERC20.balanceOf(address(autoExit));
        uint256 contractDAIBalanceBefore = DAI.balanceOf(address(autoExit));

        uint256 ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint256 ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        (,,,,,,, uint128 liquidity,,,,) = NPM.positions(TEST_NFT_2);

        // test max withdraw slippage
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert("Price slippage check");
        autoExit.execute(
            AutoExit.ExecuteParams(
                TEST_NFT_2,
                "",
                type(uint256).max,
                type(uint256).max,
                block.timestamp,
                onlyFees ? MAX_FEE_REWARD : MAX_REWARD
            )
        );

        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(
            AutoExit.ExecuteParams(
                TEST_NFT_2, "", 0, 0, block.timestamp, onlyFees ? MAX_FEE_REWARD : MAX_REWARD
            )
        ); // max fee with 1% is 7124618988448545

        (,,,,,,, liquidity,,,,) = NPM.positions(TEST_NFT_2);

        // is not runnable anymore because configuration was removed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Constants.NotConfigured.selector);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, "", 0, 0, block.timestamp, MAX_REWARD));

        // fee stored for owner in contract (only WETH because WETH is target token)
        assertEq(
            WETH_ERC20.balanceOf(address(autoExit)) - contractWETHBalanceBefore,
            onlyFees ? 4948445849078767 : 1267257651391530
        );
        assertEq(
            DAI.balanceOf(address(autoExit)) - contractDAIBalanceBefore,
            onlyFees ? 15583880997003094503 : 779194049850154725
        );

        // leftovers returned to owner
        assertEq(
            DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore,
            onlyFees ? 296093738943058795843 : 310898425890211735621
        ); // all available
        assertEq(
            TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, onlyFees ? 501954614707533274 : 505635802905220511
        ); // all available
    }

}
