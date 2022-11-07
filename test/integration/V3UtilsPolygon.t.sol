// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestBase.sol";
import "../../src/V3Utils.sol";

contract V3UtilsPolygonIntegrationTest is Test, TestBase {

    V3Utils c;
    uint256 mainnetFork;

    address constant TEST_ACCOUNT = 0xDAA27d84ea816F28F4c420F7b0AD6a9998B7e305;
    uint constant TEST_NFT_ID = 374272; // DAI/USCD 0.05% - one sided only DAI - current tick is near -276326

    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.ankr.com/polygon", 34633114);
        vm.selectFork(mainnetFork);
        c = new V3Utils(NPM);
    }
}
