// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/compound/Unitroller.sol";
import "../../src/compound/Comptroller.sol";
import "../../src/compound/WhitePaperInterestRateModel.sol";
import "../../src/compound/CErc20Delegate.sol";
import "../../src/compound/CErc20Delegator.sol";

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

        // value from mainnet comptroller
        comptroller._setCloseFactor(500000000000000000); // 50%
        comptroller._setLiquidationIncentive(1080000000000000000); // 108%

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

        module = new CollateralModule(holder, address(comptroller));

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

    struct PositionData {
        address owner;
        uint tokenId; 
        uint128 liquidity; 
        uint amount0; 
        uint amount1; 
        uint fees0; 
        uint fees1; 
        uint cAmount0; 
        uint cAmount1;
    }

    function _preparePositionCollateralDAIUSDCInRangeWithFees() internal returns (PositionData memory data) {

        data.owner = TEST_NFT_WITH_FEES_ACCOUNT;
        data.tokenId = TEST_NFT_WITH_FEES;

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, abi.encode(CollateralModule.PositionConfigParams(false)));

        vm.prank(data.owner);
        NPM.safeTransferFrom(
                data.owner,
                address(holder),
                data.tokenId,
                abi.encode(params)
            );

        (uint[] memory tokenIds,,) = module.getTokensOfOwner(data.owner);
        assertEq(tokenIds.length, 1);

        (data.liquidity, data.amount0, data.amount1, data.fees0, data.fees1, data.cAmount0, data.cAmount1) = module.getTokenBreakdown(data.tokenId, oracle.getUnderlyingPrice(cTokenDAI), oracle.getUnderlyingPrice(cTokenUSDC));

        assertEq(data.liquidity, 12922419498089422291);
        assertEq(data.amount0, 37792545112113042069479);
        assertEq(data.amount1, 39622351929);
        assertEq(data.fees0, 363011977924869600719);
        assertEq(data.fees1, 360372013);
        assertEq(data.cAmount0, 0);
        assertEq(data.cAmount1, 0);
    }

    function _preparePositionCollateralDAIWETHOutOfRangeWithFees(bool lent) internal returns (PositionData memory data) {

        data.owner = TEST_NFT_2_ACCOUNT;
        data.tokenId = TEST_NFT_2;

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, abi.encode(CollateralModule.PositionConfigParams(lent)));

        vm.prank(data.owner);
        NPM.safeTransferFrom(
                data.owner,
                address(holder),
                data.tokenId,
                abi.encode(params)
            );

        (uint[] memory tokenIds,,) = module.getTokensOfOwner(data.owner);
        assertEq(tokenIds.length, 1);

        (data.liquidity, data.amount0, data.amount1, data.fees0, data.fees1, data.cAmount0, data.cAmount1) = module.getTokenBreakdown(data.tokenId, oracle.getUnderlyingPrice(cTokenDAI), oracle.getUnderlyingPrice(cTokenWETH));

        if (lent) {
            // if lent all liquidity is moved to ctoken, only other fee token may be still available
            assertEq(data.liquidity, 0);
            assertEq(data.amount0, 0);
            assertEq(data.amount1, 0);
            assertEq(data.fees0, 311677619940061890346);
            assertEq(data.fees1, 0);
            assertEq(data.cAmount0, 0);
            assertEq(data.cAmount1, 506903060556612041);
        } else {
            // original onesided position
            assertEq(data.liquidity, 80059851033970806503);
            assertEq(data.amount0, 0);
            assertEq(data.amount1, 407934143575036696);
            assertEq(data.fees0, 311677619940061890346);
            assertEq(data.fees1, 98968916981575345);
            assertEq(data.cAmount0, 0);
            assertEq(data.cAmount1, 0);
        }
    }

    function _prepareAvailableUSDC(uint amount) internal {
        vm.prank(USDC_WHALE);   
        USDC.approve(address(cTokenUSDC), amount);
        vm.prank(USDC_WHALE);   
        cTokenUSDC.mint(amount);
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

        PositionData memory data = _preparePositionCollateralDAIUSDCInRangeWithFees();

        uint borrowAmount = 100000000;

        _prepareAvailableUSDC(borrowAmount);

        // borrow all there is
        vm.prank(data.owner);
        err = cTokenUSDC.borrow(borrowAmount);
        assertEq(err, 0);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertEq(liquidity, 38978449275567534888584);
        assertEq(shortfall, 0);

        // increase time
        vm.roll(block.number + 1);

        err = cTokenUSDC.accrueInterest();
        assertEq(err, 0);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertLt(liquidity, 38978449275567534888584); // fees were added
        assertEq(shortfall, 0);
    }

    function testGetCollateralValueNotLent() external {

        uint err;
        uint liquidity;
        uint shortfall;

        PositionData memory data = _preparePositionCollateralDAIWETHOutOfRangeWithFees(false);
        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertEq(liquidity, 540729630887579142348);
        assertEq(shortfall, 0);     
    }

    function testGetCollateralValueLent() external {

        uint err;
        uint liquidity;
        uint shortfall;

        PositionData memory data = _preparePositionCollateralDAIWETHOutOfRangeWithFees(true);
        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertEq(liquidity, 540729630887579142348);
        assertEq(shortfall, 0);     
    }

    function _prepareLiquidationScenario() internal returns (PositionData memory data) {

        uint err;
        uint liquidity;
        uint shortfall;

        data = _preparePositionCollateralDAIUSDCInRangeWithFees();

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertEq(liquidity, 39078446572567534888584);
        assertEq(shortfall, 0);

        uint lendAmount = 39078000000;
        _prepareAvailableUSDC(lendAmount);

        uint bb = USDC.balanceOf(data.owner);

        // borrow all there is
        vm.prank(data.owner);
        err = cTokenUSDC.borrow(lendAmount);
        assertEq(err, 0);

        uint ba = USDC.balanceOf(data.owner);

        assertEq(ba - bb, lendAmount);

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertEq(liquidity, 1502850907534888584); // 1 USD liquidity left
        assertEq(shortfall, 0);

        // move oracle price of USDC to $1.01
        vm.mockCall(CHAINLINK_USDC_USD, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(uint80(0), int256(101000000), block.timestamp, block.timestamp, uint80(0)));
    
        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertEq(liquidity, 0);
        assertEq(shortfall, 327613650189133661102); // 327 USD missing after price change
    }

    function testLiquidation() external {
        PositionData memory data = _prepareLiquidationScenario();

        uint256 err;
        uint256 liquidity;
        uint256 fees0;
        uint256 fees1;
        uint256 cToken0;
        uint256 cToken1;

        uint repayAmount = 39078000000 / 2;

        err = comptroller.liquidateBorrowAllowedUniV3(address(cTokenUSDC), data.tokenId, USDC_WHALE, data.owner, repayAmount);
        assertEq(err, 0);

        (err, liquidity, fees0, fees1, cToken0, cToken1) = comptroller.liquidateCalculateSeizeTokensUniV3(address(cTokenUSDC), data.tokenId, repayAmount);
       
        assertEq(err, 0);
        assertEq(liquidity, 3430081225379852442);
        assertEq(fees0, 363011977924869600719);
        assertEq(fees1, 360372013);
        assertEq(cToken0, 0);
        assertEq(cToken1, 0);

        // whale executing liquidation
        vm.prank(USDC_WHALE);   
        USDC.approve(address(cTokenUSDC), repayAmount);
        
        uint bbdai = DAI.balanceOf(USDC_WHALE);
        uint bbusdc = USDC.balanceOf(USDC_WHALE);

        vm.prank(USDC_WHALE);
        (err) = cTokenUSDC.liquidateBorrowUniV3(data.owner, repayAmount, data.tokenId);
        assertEq(err, 0);

        uint badai = DAI.balanceOf(USDC_WHALE);
        uint bausdc = USDC.balanceOf(USDC_WHALE);

        // around 108% of repayAmount
        assertEq(badai - bbdai, 11469587512910263224405);
        assertEq(repayAmount + bausdc - bbusdc, 9802285514);
    }
}
