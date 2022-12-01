// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "compound-protocol/Unitroller.sol";
import "compound-protocol/WhitePaperInterestRateModel.sol";
import "compound-protocol/CErc20Delegate.sol";
import "compound-protocol/CErc20Delegator.sol";

import "../TestBase.sol";

import "../../src/NFTHolder.sol";
import "../../src/modules/CollateralModule.sol";


contract CollateralModuleTest is Test, TestBase {
    NFTHolder holder;
    CollateralModule module;
    ChainlinkOracle oracle;
    uint256 mainnetFork;
    uint8 moduleIndex;

    Unitroller unitroller;
    Comptroller comptroller;
    InterestRateModel irm;
    CErc20 cTokenUSDC;
    CErc20 cTokenDAI;
    CErc20 cTokenWETH;
    CErc20Delegate cErc20Delegate;

    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);

        // SETUP complete custom COMPOUND
        unitroller = new Unitroller();
        comptroller = new Comptroller();

        unitroller._setPendingImplementation(address(comptroller));
        comptroller._become(unitroller);

        // change comptroller to proxy unitroller
        comptroller = Comptroller(address(unitroller));

        oracle = new ChainlinkOracle();
        oracle.setTokenFeed(address(USDC), AggregatorV3Interface(CHAINLINK_USDC_USD), 3600 * 48);
        oracle.setTokenFeed(address(DAI), AggregatorV3Interface(CHAINLINK_DAI_USD), 3600 * 48);
        oracle.setTokenFeed(address(WETH_ERC20), AggregatorV3Interface(CHAINLINK_ETH_USD), 3600);

        comptroller._setPriceOracle(oracle);

        irm = new WhitePaperInterestRateModel(20000000000000000, 300000000000000000);

        cErc20Delegate = new CErc20Delegate();

        cTokenUSDC = CErc20(address(new CErc20Delegator(address(USDC), comptroller, irm, 1 ether, "cUSDC", "cUSDC", 8, payable(address(this)), address(cErc20Delegate), "")));
        cTokenDAI = CErc20(address(new CErc20Delegator(address(DAI), comptroller, irm, 1 ether, "cDAI", "cDAI", 8, payable(address(this)), address(cErc20Delegate), "")));
        cTokenWETH = CErc20(address(new CErc20Delegator(address(WETH_ERC20), comptroller, irm, 1 ether, "cWETH", "cWETH", 8, payable(address(this)), address(cErc20Delegate), "")));

        uint64 fiftyPercent = 5 * 10 ** 17;

        comptroller._supportMarket(cTokenUSDC);
        comptroller._setCollateralFactor(cTokenUSDC, fiftyPercent);
        comptroller._supportMarket(cTokenDAI);
        comptroller._setCollateralFactor(cTokenDAI, fiftyPercent);
        comptroller._supportMarket(cTokenWETH);
        comptroller._setCollateralFactor(cTokenWETH, fiftyPercent);

        /// setup
        holder = new NFTHolder(NPM);

        module = new CollateralModule(holder, comptroller);

        // link module to comptroller
        comptroller._setCollateralModule(module);

        module.setPoolConfig(TEST_NFT_WITH_FEES_POOL, true, uint64(Q64 / 100));
        module.setPoolConfig(TEST_NFT_ETH_USDC_POOL, true, uint64(Q64 / 100));
        module.setPoolConfig(TEST_NFT_2_POOL, true, uint64(Q64 / 100));

        module.setTokenConfig(address(USDC), true, cTokenUSDC);
        module.setTokenConfig(address(DAI), true, cTokenDAI);
        module.setTokenConfig(address(WETH_ERC20), true, cTokenWETH);

        moduleIndex = holder.addModule(module, true, 0); // must be added with checkoncollect
    }

    function testBasicCompound() external {
        uint err;
        uint liquidity;
        uint shortfall;

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(TEST_NFT_ETH_USDC_ACCOUNT);
        assertEq(err, 0);
        assertEq(liquidity, 0);
        assertEq(shortfall, 0);

        // get some dollars
        vm.prank(TEST_ACCOUNT);
        USDC.transfer(TEST_NFT_ETH_USDC_ACCOUNT, 1000000);

        address[] memory tokens = new address[](3);
        tokens[0] = address(cTokenUSDC);
        tokens[1] = address(cTokenDAI);
        tokens[2] = address(cTokenWETH);

        vm.prank(TEST_NFT_ETH_USDC_ACCOUNT);
        comptroller.enterMarkets(tokens);

        vm.prank(TEST_NFT_ETH_USDC_ACCOUNT);
        USDC.approve(address(cTokenUSDC), 1000000);

        vm.prank(TEST_NFT_ETH_USDC_ACCOUNT);
        cTokenUSDC.mint(1000000);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(TEST_NFT_ETH_USDC_ACCOUNT);
        assertEq(err, 0);
        assertEq(liquidity, 499986485000000000);
        assertEq(shortfall, 0);
    }

    function testGetCollateralValue() external {

        uint err;
        uint liquidity;
        uint shortfall;

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, abi.encode(CollateralModule.PositionConfigParams(false)));

        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);
        NPM.safeTransferFrom(
                TEST_NFT_WITH_FEES_ACCOUNT,
                address(holder),
                TEST_NFT_WITH_FEES,
                abi.encode(params)
            );

        (uint[] memory tokenIds,,) = module.getTokensOfOwner(TEST_NFT_WITH_FEES_ACCOUNT);
        assertEq(tokenIds.length, 1);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(TEST_NFT_WITH_FEES_ACCOUNT);
        assertEq(err, 0);
        assertEq(liquidity, 39078446572567534888584);
        assertEq(shortfall, 0);

        // someone lends 100 USDC
        vm.prank(TEST_ACCOUNT);   
        USDC.approve(address(cTokenUSDC), 100000000);
        vm.prank(TEST_ACCOUNT);   
        cTokenUSDC.mint(100000000);

        // borrow all there is
        vm.prank(TEST_NFT_WITH_FEES_ACCOUNT);
        err = cTokenUSDC.borrow(100000000);
        assertEq(err, 0);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(TEST_NFT_WITH_FEES_ACCOUNT);
        assertEq(err, 0);
        assertEq(liquidity, 38978449275567534888584);
        assertEq(shortfall, 0);

        // increase time
        vm.roll(block.number + 1);

        err = cTokenUSDC.accrueInterest();
        assertEq(err, 0);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(TEST_NFT_WITH_FEES_ACCOUNT);
        assertEq(err, 0);
        assertLt(liquidity, 38978449275567534888584); // fees were added
        assertEq(shortfall, 0);
    }

    function testGetCollateralValueNotLent() external {

        uint err;
        uint liquidity;
        uint shortfall;

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, abi.encode(CollateralModule.PositionConfigParams(false)));

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.safeTransferFrom(
                TEST_NFT_2_ACCOUNT,
                address(holder),
                TEST_NFT_2,
                abi.encode(params)
            );

        (bool isLendable, uint cTokenAmount, bool isCToken0) = module.positionConfigs(TEST_NFT_2);
        assertEq(isLendable, false);
        assertEq(cTokenAmount, 0);
        assertEq(isCToken0, false);

        (uint[] memory tokenIds,,) = module.getTokensOfOwner(TEST_NFT_2_ACCOUNT);
        assertEq(tokenIds.length, 1);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(err, 0);
        assertEq(liquidity, 540729630887579142348);
        assertEq(shortfall, 0);      
    }

    function testGetCollateralValueLent() external {

        uint err;
        uint liquidity;
        uint shortfall;

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, abi.encode(CollateralModule.PositionConfigParams(true)));

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.safeTransferFrom(
                TEST_NFT_2_ACCOUNT,
                address(holder),
                TEST_NFT_2,
                abi.encode(params)
            );

        (bool isLendable, uint cTokenAmount, bool isCToken0) = module.positionConfigs(TEST_NFT_2);
        assertEq(isLendable, true);
        assertGt(cTokenAmount, 0);
        assertEq(isCToken0, false);

        (uint[] memory tokenIds,,) = module.getTokensOfOwner(TEST_NFT_2_ACCOUNT);
        assertEq(tokenIds.length, 1);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(TEST_NFT_2_ACCOUNT);
        assertEq(err, 0);
        assertEq(liquidity, 540729630887579142348);
        assertEq(shortfall, 0);      
    }

/*
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

    
 */  
}
