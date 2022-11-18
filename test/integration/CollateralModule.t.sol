// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestBase.sol";

import "../../src/NFTHolder.sol";
import "../../src/modules/CollateralModule.sol";

contract CollateralModuleTest is Test, TestBase {
    NFTHolder holder;
    CollateralModule module;
    ChainlinkOracle oracle;
    uint256 mainnetFork;
    uint8 moduleIndex;

    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);

        holder = new NFTHolder(NPM);
        
        oracle = new ChainlinkOracle();
        oracle.setTokenFeed(address(USDC), AggregatorV3Interface(CHAINLINK_USDC_USD), 3600 * 24);
        oracle.setTokenFeed(address(DAI), AggregatorV3Interface(CHAINLINK_DAI_USD), 3600 * 24);
        oracle.setTokenFeed(address(WETH_ERC20), AggregatorV3Interface(CHAINLINK_ETH_USD), 3600);
        
        // simulate empty liquidity response from comptroller
        vm.mockCall(COMPOUND_COMPTROLLER, abi.encodeWithSelector(Comptroller.getAccountLiquidity.selector), abi.encode(ComptrollerErrorReporter.Error.NO_ERROR, 0, 0));

        module = new CollateralModule(holder, Comptroller(COMPOUND_COMPTROLLER), oracle);

        module.setPoolConfig(TEST_NFT_WITH_FEES_POOL, CollateralModule.PoolConfig(true, uint64(Q64 - 1), uint64(Q64 / 100)));
        module.setPoolConfig(TEST_NFT_ETH_USDC_POOL, CollateralModule.PoolConfig(true, uint64(Q64 - 1), uint64(Q64 / 100)));

        module.setTokenConfig(address(USDC), true);
        module.setTokenConfig(address(DAI), true);
        module.setTokenConfig(address(WETH_ERC20), true);

        moduleIndex = holder.addModule(module, true, 0); // must be added with checkoncollect
    }

    function testGetWithoutConfiguredTokens() external {

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, "");

        vm.prank(TEST_NFT_ETH_USDC_ACCOUNT);
        NPM.safeTransferFrom(
                TEST_NFT_ETH_USDC_ACCOUNT,
                address(holder),
                TEST_NFT_ETH_USDC,
                abi.encode(params)
            );

        uint value1 = module.getCollateralValue(TEST_NFT_ETH_USDC);
        assertEq(value1, 6762980324); // 6762 USD - based on oracle price
    }

    function testGetCollateralValue() external {

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, "");

        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);
        NPM.safeTransferFrom(
                TEST_NFT_WITH_FEES_ACCOUNT,
                address(holder),
                TEST_NFT_WITH_FEES,
                abi.encode(params)
            );

        uint value1 = module.getCollateralValue(TEST_NFT_WITH_FEES);
        assertEq(value1, 78156849778); // 78156 USD - based on oracle price

        // decrease all fees
        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_WITH_FEES, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, address(this)));

        uint value2 = module.getCollateralValue(TEST_NFT_WITH_FEES);
        assertEq(value2, 77433288564); // 77433 USD - based on oracle price

        // decrease all liquidity
        (,,,,,,,uint128 liquidity, , , , ) =  NPM.positions(TEST_NFT_WITH_FEES);
        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_WITH_FEES, liquidity, 0, 0, 0, 0, block.timestamp, address(this)));

        uint value3 = module.getCollateralValue(TEST_NFT_WITH_FEES);
        assertEq(value3, 0); // 0 USD - empty position
    }
   
}
