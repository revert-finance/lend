// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestBase.sol";

import "../../src/NFTHolder.sol";
import "../../src/modules/StopLossLimitModule.sol";

contract StopLossLimitModuleTest is Test, TestBase {
    NFTHolder holder;
    StopLossLimitModule module;
    uint256 mainnetFork;
    uint8 moduleIndex;

    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.flashbots.net", 15489169);
        vm.selectFork(mainnetFork);

        holder = new NFTHolder(NPM);
        module = new StopLossLimitModule(holder, EX0x);

        assertEq(
            address(module.factory()),
            0x1F98431c8aD98523631AE4a59f267346ea31F984
        );

        moduleIndex = holder.addModule(module, 0);
    }

    function _addToModule(
        bool firstTime,
        uint tokenId,
        bool token0Swap,
        bool token1Swap,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        int24 token0TriggerTick,
        int24 token1TriggerTick
    ) internal {
        StopLossLimitModule.PositionConfig memory config = StopLossLimitModule.PositionConfig(
                token0Swap,
                token1Swap,
                token0SlippageX64,
                token1SlippageX64,
                token0TriggerTick,
                token1TriggerTick
            );

        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, abi.encode(config));

        if (firstTime) {
            vm.prank(TEST_ACCOUNT);
            NPM.safeTransferFrom(
                TEST_ACCOUNT,
                address(holder),
                tokenId,
                abi.encode(params)
            );
        } else {
            vm.prank(TEST_ACCOUNT);
            holder.addTokenToModule(tokenId, params[0]);
        }
    }

    function testAddAndRemove() external {

        _addToModule(true, TEST_NFT_ID, false, false, 0, 0, type(int24).min, type(int24).max);

        vm.prank(TEST_ACCOUNT);
        holder.removeTokenFromModule(TEST_NFT_ID, moduleIndex);

        vm.prank(TEST_ACCOUNT);
        holder.withdrawToken(TEST_NFT_ID, TEST_ACCOUNT, "");
    }

    function testNoLiquidity() external {
        _addToModule(true, TEST_NFT_ID, false, false, 0, 0, type(int24).min, type(int24).max);

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_ID);

        assertEq(liquidity, 0);

        vm.expectRevert(StopLossLimitModule.NoLiquidity.selector);
        module.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_ID, ""));
    }

    function _addLiquidity() internal returns (uint256 amount0, uint256 amount1) {
         // add onesided liquidity
        vm.startPrank(TEST_ACCOUNT);
        DAI.approve(address(NPM), 1000000000000000000);
        (
            ,
            amount0,
            amount1
        ) = NPM.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(TEST_NFT_ID, 1000000000000000000, 0, 0, 0, block.timestamp));

        assertEq(amount0, 999999999999999633);
        assertEq(amount1, 0);

        vm.stopPrank();
    }

    function testRangesAndActions() external {

        (uint amount0, uint amount1) = _addLiquidity();
        
        (, ,address token0, address token1, uint24 fee , int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_ID);

        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(FACTORY, PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})));

        (, int24 tick, , , , , ) = pool.slot0();

        assertGt(liquidity, 0);
        assertEq(tickLower, -276320);
        assertEq(tickUpper, -276310);
        assertEq(tick, -276325);
    
        _addToModule(true, TEST_NFT_ID, false, false, 0, 0, -276325, type(int24).max);
        vm.expectRevert(StopLossLimitModule.NotInCondition.selector);
        module.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_ID, ""));

        uint balanceBeforeOwner = DAI.balanceOf(TEST_ACCOUNT);

        _addToModule(false, TEST_NFT_ID, false, false, 0, 0, -276324, type(int24).max);

        // execute limit order - without swap
        module.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_ID, ""));

        (, ,, , ,, ,liquidity, , , , ) = NPM.positions(TEST_NFT_ID);
        assertEq(liquidity, 0);

        uint balanceAfterOwner = DAI.balanceOf(TEST_ACCOUNT);

        // check paid fee
        uint balanceBefore = DAI.balanceOf(address(this));
        module.withdrawBalance(address(DAI), address(this));
        uint balanceAfter = DAI.balanceOf(address(this));

        assertEq(balanceAfterOwner + balanceAfter - balanceBeforeOwner - balanceBefore + 1, amount0); // +1 because Uniswap imprecision (remove same liquidity returns 1 less)

        // cant execute again - liquidity disapeard
        vm.expectRevert(StopLossLimitModule.NoLiquidity.selector);
        module.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_ID, ""));

        // add new liquidity
        (amount0, amount1) = _addLiquidity();

        // change to swap
        _addToModule(false, TEST_NFT_ID, true, false, uint64(Q64 / 100), uint64(Q64 / 100), -276324, type(int24).max);

        // execute stop loss order - with swap
        uint swapBalanceBefore = USDC.balanceOf(TEST_ACCOUNT);
        module.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_ID, _get999999999999999632DAIToUSDSwapData()));
        uint swapBalanceAfter = USDC.balanceOf(TEST_ACCOUNT);
        
        balanceBefore = USDC.balanceOf(address(this));
        module.withdrawBalance(address(USDC), address(this));
        balanceAfter = USDC.balanceOf(address(this));

        assertEq(swapBalanceAfter - swapBalanceBefore, 988879);
        assertEq(balanceAfter - balanceBefore, 4969);
    }

    function _get999999999999999632DAIToUSDSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=999999999999999632&slippagePercentage=0.05
        return
            abi.encode(
                EX0x,
                hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a763fe9000000000000000000000000000000000000000000000000000000000000e777d000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000045643479ef636e6e94"
            );
    }
}
