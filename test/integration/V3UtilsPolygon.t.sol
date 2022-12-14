// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestBase.sol";
import "../../src/V3Utils.sol";

// temp contract to do on chain tests during development
contract V3UtilsPolygonIntegrationTest is Test, TestBase {
    V3Utils c;
    uint256 mainnetFork;
    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.ankr.com/polygon", 36835056);
        vm.selectFork(mainnetFork);
        c = V3Utils(payable(0x7763424F9A29263eBd6F269122E6db2562F8cD81));
    }

    function testSwapAndIncreaseLiquidity() external {

        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils
            .SwapAndIncreaseLiquidityParams(
                548087,
                139814970433852455,
                75149461170897680,
                0xDAA27d84ea816F28F4c420F7b0AD6a9998B7e305,
                1671053298,
                IERC20(address(0)),
                0,
                0,
                "",
                0,
                0,
                "",
                0,
                0
            );

        assertEq(V3Utils.swapAndIncreaseLiquidity.selector, hex"a161848b");

        vm.prank(0xDAA27d84ea816F28F4c420F7b0AD6a9998B7e305);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = c.swapAndIncreaseLiquidity(params);
    }
}
