// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract CollateralModuleTest is TestBase {
    uint8 moduleIndex;

    function setUp() external {
        _setupBase();
        moduleIndex = _setupCollateralModule();
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

        (uint[] memory tokenIds,,) = collateralModule.getPositionsOfOwner(data.owner);
        assertEq(tokenIds.length, 1);

        (data.liquidity, data.amount0, data.amount1, data.fees0, data.fees1, data.cAmount0, data.cAmount1) = collateralModule.getPositionBreakdown(data.tokenId, oracle.getUnderlyingPrice(cTokenDAI), oracle.getUnderlyingPrice(cTokenUSDC));

        assertEq(data.liquidity, 12922419498089422291);
        assertEq(data.amount0, 37792545112113042069479);
        assertEq(data.amount1, 39622351929);
        assertEq(data.fees0, 363011977924869600719);
        assertEq(data.fees1, 360372013);
        assertEq(data.cAmount0, 0);
        assertEq(data.cAmount1, 0);
    }

    function _preparePositionCollateralDAIWETHOutOfRangeWithFees(bool lendable) internal returns (PositionData memory data) {

        data.owner = TEST_NFT_2_ACCOUNT;
        data.tokenId = TEST_NFT_2;

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, abi.encode(CollateralModule.PositionConfigParams(lendable)));

        vm.prank(data.owner);
        NPM.safeTransferFrom(
                data.owner,
                address(holder),
                data.tokenId,
                abi.encode(params)
            );

        (uint[] memory tokenIds,,) = collateralModule.getPositionsOfOwner(data.owner);
        assertEq(tokenIds.length, 1);

        (data.liquidity, data.amount0, data.amount1, data.fees0, data.fees1, data.cAmount0, data.cAmount1) = collateralModule.getPositionBreakdown(data.tokenId, oracle.getUnderlyingPrice(cTokenDAI), oracle.getUnderlyingPrice(cTokenWETH));

        if (lendable) {
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
        vm.prank(WHALE_ACCOUNT);   
        USDC.approve(address(cTokenUSDC), amount);
        vm.prank(WHALE_ACCOUNT);   
        cTokenUSDC.mint(amount);
    }

    function _prepareAvailableDAI(uint amount) internal {
        vm.prank(WHALE_ACCOUNT);   
        DAI.approve(address(cTokenDAI), amount);
        vm.prank(WHALE_ACCOUNT);   
        cTokenDAI.mint(amount);
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

    function testRemoveCollateralWhenNeeded() external {

        PositionData memory data = _preparePositionCollateralDAIUSDCInRangeWithFees();

        uint borrowAmount = 100000000;
        _prepareAvailableUSDC(borrowAmount);

        // borrow all there is
        vm.prank(data.owner);
        uint err = cTokenUSDC.borrow(borrowAmount);
        assertEq(err, 0);

        // fails when removing token (collateral is needed)
        vm.prank(data.owner);
        vm.expectRevert(CollateralModule.NotAllowed.selector);
        holder.withdrawToken(data.tokenId, data.owner, "");

        vm.prank(data.owner);   
        USDC.approve(address(cTokenUSDC), borrowAmount);

        vm.prank(data.owner);
        cTokenUSDC.repayBorrow(borrowAmount);

        // now can be withdrawn (debt was repayed)
        vm.prank(data.owner);
        holder.withdrawToken(data.tokenId, data.owner, "");
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

    function testLendingWithKeeper() external {
        PositionData memory data = _preparePositionCollateralDAIWETHOutOfRangeWithFees(true);

        // owner may unlend always
        vm.prank(data.owner);
        collateralModule.unlend(data.tokenId);

        // other account only may lend because "enough out of range"
        vm.prank(WHALE_ACCOUNT);
        collateralModule.lend(data.tokenId);

        // may not unlend because not enough close to "in range" - with default config
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(CollateralModule.PositionNotInValidTick.selector);
        collateralModule.unlend(data.tokenId);
    }

    function testGrowShrinkPositionWithBorrowing() external {

        uint err;
        uint liquidity;
        uint shortfall;

        PositionData memory data = _preparePositionCollateralDAIUSDCInRangeWithFees();

        // prepare borrowable tokens 1000000 DAI / 1000000 USDC
        _prepareAvailableDAI(100000 ether);
        _prepareAvailableUSDC(100000000000);


        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertEq(liquidity, 39078446572567534888584); // fees were added
        assertEq(shortfall, 0);

        (, , , , , , , uint128 liquidityBefore, , , , ) = NPM.positions(data.tokenId);

        vm.prank(data.owner);
        collateralModule.borrowAndAddLiquidity(CollateralModule.BorrowAndAddLiquidityParams(data.tokenId, 5000000000000000000, 0, 0));
     
        (, , , , , , , uint128 liquidityAfter, , , , ) = NPM.positions(data.tokenId);

        assertGt(liquidityAfter, liquidityBefore); 

        (err, liquidity, shortfall) = comptroller.getAccountLiquidity(data.owner);
        assertEq(err, 0);
        assertEq(liquidity, 24097530741284063731072); // fees were added
        assertEq(shortfall, 0);

        collateralModule.repayFromRemovedLiquidity(CollateralModule.RepayFromRemovedLiquidityParams(data.tokenId, 5000000000000000000, 0, 0, 0, 0));

        (, , , , , , , liquidityBefore, , , , ) = NPM.positions(data.tokenId);

        assertGt(liquidityAfter, liquidityBefore); 

        collateralModule.repayFromRemovedLiquidity(CollateralModule.RepayFromRemovedLiquidityParams(data.tokenId, liquidityBefore, 0, 0, 0, 0));

        (, , , , , , , liquidityBefore, , , , ) = NPM.positions(data.tokenId);

        assertEq(liquidityBefore, 0);
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

        err = comptroller.liquidateBorrowAllowedUniV3(address(cTokenUSDC), data.tokenId, WHALE_ACCOUNT, data.owner, repayAmount);
        assertEq(err, 0);

        (err, liquidity, fees0, fees1, cToken0, cToken1) = comptroller.liquidateCalculateSeizeTokensUniV3(address(cTokenUSDC), data.tokenId, repayAmount);
       
        assertEq(err, 0);
        assertEq(liquidity, 3430081225379852442);
        assertEq(fees0, 363011977924869600719);
        assertEq(fees1, 360372013);
        assertEq(cToken0, 0);
        assertEq(cToken1, 0);

        // whale executing liquidation
        vm.prank(WHALE_ACCOUNT);   
        USDC.approve(address(cTokenUSDC), repayAmount);
        
        uint bbdai = DAI.balanceOf(WHALE_ACCOUNT);
        uint bbusdc = USDC.balanceOf(WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        (err) = cTokenUSDC.liquidateBorrowUniV3(data.owner, repayAmount, data.tokenId);
        assertEq(err, 0);

        uint badai = DAI.balanceOf(WHALE_ACCOUNT);
        uint bausdc = USDC.balanceOf(WHALE_ACCOUNT);

        // around 108% of repayAmount
        assertEq(badai - bbdai, 11469587512910263224405);
        assertEq(repayAmount + bausdc - bbusdc, 9802285514);
    }
}
