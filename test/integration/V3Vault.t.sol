// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// base contracts
import "../../src/V3Oracle.sol";
import "../../src/V3Vault.sol";
import "../../src/InterestRateModel.sol";

// transformers
import "../../src/transformers/LeverageTransformer.sol";
import "../../src/transformers/V3Utils.sol";
import "../../src/transformers/AutoRange.sol";
import "../../src/transformers/AutoCompound.sol";

import "../../src/utils/FlashloanLiquidator.sol";

import "../../src/interfaces/IErrors.sol";

contract V3VaultIntegrationTest is Test {
   
    uint constant Q32 = 2 ** 32;
    uint constant Q96 = 2 ** 96;

    uint constant YEAR_SECS = 31557600; // taking into account leap years

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy
    address UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address constant UNISWAP_DAI_USDC = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168; // 0.01% pool
    address constant UNISWAP_ETH_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // 0.05% pool

    address constant TEST_NFT_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    uint256 constant TEST_NFT = 126; // DAI/USDC 0.05% - in range (-276330/-276320)

    address constant TEST_NFT_ACCOUNT_2 = 0x454CE089a879F7A0d0416eddC770a47A1F47Be99;
    uint256 constant TEST_NFT_2 = 1047; // DAI/USDC 0.05% - in range (-276330/-276320)

    uint256 constant TEST_NFT_UNI = 1; // WETH/UNI 0.3%

    uint256 mainnetFork;

    V3Vault vault;
    
    InterestRateModel interestRateModel;
    V3Oracle oracle;

    function setUp() external {

        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 18521658);
        vm.selectFork(mainnetFork);

        // 0% base rate - 5% multiplier - after 80% - 109% jump multiplier (like in compound v2 deployed)  (-> max rate 25.8% per year)
        interestRateModel = new InterestRateModel(0, Q96 * 5 / 100, Q96 * 109 / 100, Q96 * 80 / 100);

        // use tolerant oracles (so timewarp for until 30 days works in tests - also allow divergence from price for mocked price results)
        oracle = new V3Oracle(NPM, address(USDC), address(0));
        oracle.setTokenConfig(address(USDC), AggregatorV3Interface(CHAINLINK_USDC_USD), 3600 * 24 * 30, IUniswapV3Pool(address(0)), 0, V3Oracle.Mode.TWAP, 0);
        oracle.setTokenConfig(address(DAI), AggregatorV3Interface(CHAINLINK_DAI_USD), 3600 * 24 * 30, IUniswapV3Pool(UNISWAP_DAI_USDC), 60, V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, 50000);
        oracle.setTokenConfig(address(WETH), AggregatorV3Interface(CHAINLINK_ETH_USD), 3600 * 24 * 30, IUniswapV3Pool(UNISWAP_ETH_USDC), 60, V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, 50000);

        vault = new V3Vault("Revert Lend USDC", "rlUSDC", address(USDC), NPM, interestRateModel, oracle);
        vault.setTokenConfig(address(USDC), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor - max 100% collateral value
        vault.setTokenConfig(address(DAI), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor - max 100%  collateral value
        vault.setTokenConfig(address(WETH), uint32(Q32 * 8 / 10), type(uint32).max); // 80% collateral factor - max 100%  collateral value

        // limits 15 USDC each
        vault.setLimits(0, 15000000, 15000000, 12000000, 12000000);

        // without reserve for now
        vault.setReserveFactor(0);
    }

    function _setupBasicLoan(bool borrowMax) internal {

        // lend 10 USDC
        _deposit(10000000, WHALE_ACCOUNT);

        // add collateral
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        (, uint fullValue, uint collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(collateralValue, 8847206);
        assertEq(fullValue, 9830229);

        if (borrowMax) {
            // borrow max
            vm.prank(TEST_NFT_ACCOUNT);
            vault.borrow(TEST_NFT, collateralValue);
        }
    }

    function _repay(uint amount, address account, uint tokenId, bool complete) internal {
        vm.prank(account);
        USDC.approve(address(vault), amount);
        if (complete) {
            (uint debtShares,) = vault.loans(tokenId);
            vm.prank(account);
            vault.repay(tokenId, debtShares, true);
        } else {
            vm.prank(account);
            vault.repay(tokenId, amount, false);
        }
    }

    function _deposit(uint amount, address account) internal {
        vm.prank(account);
        USDC.approve(address(vault), amount);
        vm.prank(account);
        vault.deposit(amount, account);
    }

    function _createAndBorrow(uint tokenId, address account, uint amount) internal {
        vm.prank(account);
        NPM.approve(address(vault), tokenId);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(V3Vault.create.selector, tokenId, account);
        calls[1] = abi.encodeWithSelector(V3Vault.borrow.selector, tokenId, amount);

        vm.prank(account);
        vault.multicall(calls);
    }

    function testMinLoanSize() external {

        uint minLoanSize = 1000000;

        vault.setLimits(1000000, 15000000, 15000000, 15000000, 15000000);

         // lend 10 USDC
        _deposit(10000000, WHALE_ACCOUNT);

        // add collateral
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.expectRevert(IErrors.MinLoanSize.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, minLoanSize - 1);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, minLoanSize);

        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(vault), minLoanSize);

        vm.expectRevert(IErrors.MinLoanSize.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.repay(TEST_NFT, 1, false);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.repay(TEST_NFT, minLoanSize, false);
    }

    function testERC20() external {

        uint assets = 10000000;

        _setupBasicLoan(false);
        assertEq(vault.balanceOf(WHALE_ACCOUNT), assets);
        assertEq(vault.lendInfo(WHALE_ACCOUNT), assets);

        vm.prank(WHALE_ACCOUNT);
        vault.transfer(TEST_NFT_ACCOUNT, assets);
        
        assertEq(vault.balanceOf(WHALE_ACCOUNT), 0);
        assertEq(vault.lendInfo(WHALE_ACCOUNT), 0);
        assertEq(vault.balanceOf(TEST_NFT_ACCOUNT), assets);
        assertEq(vault.lendInfo(TEST_NFT_ACCOUNT), assets);
    }

    // fuzz testing deposit amount
    function testDeposit(uint amount) external {

        uint balance = USDC.balanceOf(WHALE_ACCOUNT);
        vm.assume(amount <= balance * 10);

        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), amount);   

        uint lendLimit = vault.globalLendLimit();
        uint dailyDepositLimit = vault.dailyLendIncreaseLimitMin();

        if (amount > balance) {
            vm.expectRevert("ERC20: transfer amount exceeds balance");
        } else if (amount > lendLimit) {
            vm.expectRevert(IErrors.GlobalLendLimit.selector);
        } else if (amount > dailyDepositLimit) {
            vm.expectRevert(IErrors.DailyLendIncreaseLimit.selector);
        }

        vm.prank(WHALE_ACCOUNT);
        vault.deposit(amount, WHALE_ACCOUNT);
    }

    // fuzz testing withdraw amount
    function testWithdraw(uint amount) external {

        bool isShare = true;

        // 0 borrow loan
        _setupBasicLoan(false);

        uint lent = vault.lendInfo(WHALE_ACCOUNT);
        uint lentShares = vault.balanceOf(WHALE_ACCOUNT);

        if (isShare) {
            vm.assume(amount <= lentShares * 10);
        } else {
            vm.assume(amount <= lent * 10);
        }
      
        if (isShare && amount > lentShares || !isShare && amount > lent) {
            vm.expectRevert(IErrors.InsufficientLiquidity.selector);
        }

        vm.prank(WHALE_ACCOUNT);
        if (isShare) {
            vault.redeem(amount, WHALE_ACCOUNT, WHALE_ACCOUNT);
        } else {
            vault.withdraw(amount, WHALE_ACCOUNT, WHALE_ACCOUNT);
        }
    }

    // fuzz testing borrow amount
    function testBorrow(uint amount) external {
        // 0 borrow loan
        _setupBasicLoan(false);

        (,,uint collateralValue,,) = vault.loanInfo(TEST_NFT);

        vm.assume(amount <= collateralValue * 100);

        uint debtLimit = vault.globalDebtLimit();
        uint increaseLimit = vault.dailyDebtIncreaseLimitMin();

        if (amount > debtLimit) {
            vm.expectRevert(IErrors.GlobalDebtLimit.selector);
        } else if (amount > increaseLimit) {
            vm.expectRevert(IErrors.DailyDebtIncreaseLimit.selector);
        } else if (amount > collateralValue) {
            vm.expectRevert(IErrors.CollateralFail.selector);
        }

        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, amount);
    }

    // fuzz testing repay amount
    function testRepay(uint amount, bool isShare) external {

        // maximized collateral loan
        _setupBasicLoan(true);

        (,,uint debt,,) = vault.loanInfo(TEST_NFT);
        (uint debtShares,) = vault.loans(TEST_NFT);

        if (isShare) {
            vm.assume(amount <= debtShares * 10);
        } else {
            vm.assume(amount <= debt * 10);
        }
        
        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(vault), debt);
       
        if (isShare && amount > debtShares || !isShare && amount > debt) {
            vm.expectRevert(IErrors.RepayExceedsDebt.selector);
        } 

        vm.prank(TEST_NFT_ACCOUNT);
        vault.repay(TEST_NFT, amount, isShare);
    }

    function testTransformLeverage() external {

        // setup transformer
        LeverageTransformer transformer = new LeverageTransformer(NPM, EX0x, UNIVERSAL_ROUTER);
        vault.setTransformer(address(transformer), true);

        // maximized collateral loan
        _setupBasicLoan(true);

        (, ,, , ,, ,uint128 liquidity, , , , ) = NPM.positions(TEST_NFT);
        assertEq(liquidity, 18828671372106658);

        (uint debt, , uint collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 8847206);
        assertEq(collateralValue, 8847206);

        // swap 300721346401315352 DAI for USDC
        bytes memory swapDAIUSDC = abi.encode(EX0x, abi.encode(Swapper.ZeroxRouterData(EX0x, hex"415565b00000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000042c6078a4a0aa1800000000000000000000000000000000000000000000000000000000000489b400000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000002100000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000002c0000000000000000000000000000000000000000000000000042c6078a4a0aa1800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000253757368695377617000000000000000000000000000000000000000000000000000000000000000042c6078a4a0aa180000000000000000000000000000000000000000000000000000000000048b72000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000d9e1ce17f2641f24ae83637ab66a2cca9c378b9f000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000001be000000000000000000000000ad01c20d5886137e056775af56915de824c8fce5000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000f4dc0cafaa63a7eda78ef966a07c8ec9")));

        // leverage down (all available tokens with swap)
        LeverageTransformer.LeverageDownParams memory params = LeverageTransformer.LeverageDownParams(
            TEST_NFT,
            liquidity / 2,
            0,
            0,
            type(uint128).max,
            type(uint128).max,
            300721346401315352, // dais for removed liquidity
            0,
            swapDAIUSDC,
            0,
            0,
            "",
            TEST_NFT_ACCOUNT,
            block.timestamp
        );

        // execute leveragedown
        vm.prank(TEST_NFT_ACCOUNT);
        vault.transform(TEST_NFT, address(transformer), abi.encodeWithSelector(LeverageTransformer.leverageDown.selector, params));

        (debt,,collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 3725220);
        assertEq(collateralValue, 4235990);

        // swap 80870 USDC for DAI (to achieve almost optimal ratio)
        bytes memory swapUSDCDAI = abi.encode(EX0x, abi.encode(Swapper.ZeroxRouterData(EX0x, hex"415565b0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000000000000000000000000000000000000000013be6000000000000000000000000000000000000000000000000011a9a57ccf7a36300000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000000210000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000034000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000002c00000000000000000000000000000000000000000000000000000000000013be6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000002556e69737761705632000000000000000000000000000000000000000000000000000000000000000000000000013be6000000000000000000000000000000000000000000000000011b070687cb870b000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000f164fc0ec4e93095b804a4795bbe1e041497b92a00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000000000006caebad3e3a8000000000000000000000000ad01c20d5886137e056775af56915de824c8fce5000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000a6510880f7d95eecdceadc756671b232")));

        // get > 4 USD extra (flashloan) swap and add collateral
        LeverageTransformer.LeverageUpParams memory params2 = LeverageTransformer.LeverageUpParams(
            TEST_NFT,
            4080870, // $4 + 0.08087
            80870,
            0,
            swapUSDCDAI,
            0,
            0,
            "",
            0,
            0,
            TEST_NFT_ACCOUNT,
            block.timestamp
        );

        // execute leverageup
        vm.prank(TEST_NFT_ACCOUNT);
        vault.transform(TEST_NFT, address(transformer), abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params2));

        (debt,,collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 7806090);
        assertEq(collateralValue, 7908458);
    }

    function testTransformWithdrawCollect() external {

        _setupBasicLoan(true);

        V3Utils v3Utils = new V3Utils(NPM, EX0x, UNIVERSAL_ROUTER, PERMIT2);
        vault.setTransformer(address(v3Utils), true);

        // test transforming with v3utils
        // withdraw fees - as an example
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(0),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            type(uint128).max,
            type(uint128).max,
            0,
            0,
            0,
            0,
            0,
            0,
            block.timestamp,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            false,
            "",
            ""
        );

        vm.expectRevert(IErrors.CollateralFail.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.transform(TEST_NFT, address(v3Utils), abi.encodeWithSelector(V3Utils.execute.selector, TEST_NFT, inst));

        // needs to repay a part first - to get fees
        _repay(1000000, TEST_NFT_ACCOUNT, TEST_NFT, false);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.transform(TEST_NFT, address(v3Utils), abi.encodeWithSelector(V3Utils.execute.selector, TEST_NFT, inst));
    }

    function testTransformChangeRange() external {

        _setupBasicLoan(true);

        V3Utils v3Utils = new V3Utils(NPM, EX0x, UNIVERSAL_ROUTER, PERMIT2);
        vault.setTransformer(address(v3Utils), true);

        (, ,, , ,, ,uint128 liquidity, , , , ) = NPM.positions(TEST_NFT);
        assertEq(liquidity, 18828671372106658);

        uint swapAmountIn = 10000000000000000;
        uint swapAmountMinOut = 100;

        // universalrouter swap data (single swap command) - swap 0.01 DAI to USDC - and sweep
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(address(v3Utils), swapAmountIn, swapAmountMinOut, abi.encodePacked(address(DAI), uint24(500), address(USDC)), false);
        inputs[1] = abi.encode(address(DAI), address(v3Utils), 0);
        bytes memory swapData = abi.encode(UNIVERSAL_ROUTER, abi.encode(Swapper.UniversalRouterData(hex"0004", inputs, block.timestamp)));



        // test transforming with v3utils - changing range
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.CHANGE_RANGE,
            address(USDC),
            0,
            0,
            swapAmountIn,
            swapAmountMinOut,
            swapData,
            0,
            0,
            "",
            type(uint128).max,
            type(uint128).max,
            500,
            -276330,
            -276320,
            liquidity,
            0,
            0,
            block.timestamp,
            TEST_NFT_ACCOUNT,
            address(vault),
            false,
            "",
            abi.encode(true)
        );

        // some collateral gets lost during change-range (fees which are not added completely in this case) - needs repayment before
        vm.expectRevert(IErrors.CollateralFail.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.transform(TEST_NFT, address(v3Utils), abi.encodeWithSelector(V3Utils.execute.selector, TEST_NFT, inst));

        // needs to repay a part first
        _repay(1000000, TEST_NFT_ACCOUNT, TEST_NFT, false);

        (uint oldDebt,,,,) = vault.loanInfo(TEST_NFT);

        vm.prank(TEST_NFT_ACCOUNT);
        uint tokenId = vault.transform(TEST_NFT, address(v3Utils), abi.encodeWithSelector(V3Utils.execute.selector, TEST_NFT, inst));

        assertGt(tokenId, TEST_NFT);


        // old loan has been removed
        (, ,, , ,, ,liquidity, , , , ) = NPM.positions(TEST_NFT);
        assertEq(liquidity, 0);
        (uint debt, uint fullValue, uint collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 0);
        assertEq(collateralValue, 0);
        assertEq(fullValue, 0);

        // new loan has been created
        (, ,, , ,, ,liquidity, , , , ) = NPM.positions(tokenId);
        assertEq(liquidity, 19275744032345419);
        (debt, fullValue, collateralValue,,) = vault.loanInfo(tokenId);

        // debt with new NFT as collateral must be the same amount as before
        assertEq(debt, oldDebt);
        
        assertEq(collateralValue, 8673141);
        assertEq(fullValue, 9636824);
    }

    function testTransformAutoCompoundOutsideVault() external {

        AutoCompound autoCompound = new AutoCompound(NPM, WHALE_ACCOUNT, WHALE_ACCOUNT, 60, 100);

        // test compounding when not in vault
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert("Not approved");
        autoCompound.execute(AutoCompound.ExecuteParams(TEST_NFT, false, 0));

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(autoCompound), TEST_NFT);

        vm.prank(WHALE_ACCOUNT);
        autoCompound.execute(AutoCompound.ExecuteParams(TEST_NFT, false, 0));
    }

    function testTransformAutoCompoundInsideVault() external {

        AutoCompound autoCompound = new AutoCompound(NPM, WHALE_ACCOUNT, WHALE_ACCOUNT, 60, 100);
        vault.setTransformer(address(autoCompound), true);
        autoCompound.setVault(address(vault), true);
  
        _setupBasicLoan(true);

        vm.expectRevert(IErrors.Unauthorized.selector);
        autoCompound.execute(AutoCompound.ExecuteParams(TEST_NFT, false, 0));

        // direct auto-compound when in vault fails
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert("Not approved");
        autoCompound.execute(AutoCompound.ExecuteParams(TEST_NFT, false, 0));

        // user hasnt approved automator
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(IErrors.Unauthorized.selector);
        autoCompound.executeWithVault(AutoCompound.ExecuteParams(TEST_NFT, false, 0), address(vault));

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoCompound), true);

        // fails because full collateral used
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(IErrors.CollateralFail.selector);
        autoCompound.executeWithVault(AutoCompound.ExecuteParams(TEST_NFT, false, 0), address(vault));

        // repay partially
        _repay(1000000, TEST_NFT_ACCOUNT, TEST_NFT, false);

        // autocompound with swap
        vm.prank(WHALE_ACCOUNT);
        autoCompound.executeWithVault(AutoCompound.ExecuteParams(TEST_NFT, false, 12345), address(vault));
    }

    function testTransformAutoRangeInsideVault() external {

        AutoRange autoRange = new AutoRange(NPM, WHALE_ACCOUNT, WHALE_ACCOUNT, 60, 100, EX0x, UNIVERSAL_ROUTER);
        vault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vault), true);
  
        _setupBasicLoan(true);

        (, ,, , ,, ,uint128 liquidity, , , , ) = NPM.positions(TEST_NFT);
        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams(TEST_NFT, false, 0, "", liquidity, 0, 0, block.timestamp, 0);

        vm.expectRevert(IErrors.Unauthorized.selector);
        autoRange.execute(params);

        // direct auto-compound when in vault fails
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(IErrors.NotConfigured.selector);
        autoRange.execute(params);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoRange), true);

        vm.prank(TEST_NFT_ACCOUNT);
        autoRange.configToken(TEST_NFT, address(vault), AutoRange.PositionConfig(-10, -10, -10, 10, 0, 0, false, 0));

        // fails because full collateral used
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(IErrors.CollateralFail.selector);
        autoRange.executeWithVault(params, address(vault));

        // repay partially
        _repay(1000000, TEST_NFT_ACCOUNT, TEST_NFT, false);

        // autorange
        vm.prank(WHALE_ACCOUNT);
        autoRange.executeWithVault(params, address(vault));


        // previous loan is deactivated - and sent back to owner
        (uint debt,,,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 0);
        assertEq(NPM.ownerOf(TEST_NFT), TEST_NFT_ACCOUNT);


        uint newTokenId = NPM.tokenByIndex(NPM.totalSupply() - 1);
        assertEq(newTokenId, 599811);

        (debt,,,,) = vault.loanInfo(newTokenId);
        assertEq(debt, 7847206);
        assertEq(NPM.ownerOf(newTokenId), address(vault));
        assertEq(vault.ownerOf(newTokenId), TEST_NFT_ACCOUNT);
    }

    function testLiquidationTimeBased() external {
        _testLiquidation(true);
    }

    function testLiquidationCollateralBased() external {
        _testLiquidation(false);
    }

    function _testLiquidation(bool timeBased) internal {

        _setupBasicLoan(true);

        (, uint fullValue, uint collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(collateralValue, 8847206);
        assertEq(fullValue, 9830229);

        // debt is equal collateral value
        (uint debt, ,,uint liquidationCost, uint liquidationValue) = vault.loanInfo(TEST_NFT);
        assertEq(debt, collateralValue);
        assertEq(liquidationCost, 0);
        assertEq(liquidationValue, 0);

        if (timeBased) {
            // wait 7 day - interest growing
            vm.warp(block.timestamp + 7 days);
        } else {
            // collateral DAI value change -100%
            vm.mockCall(CHAINLINK_DAI_USD, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(uint80(0), int256(0), block.timestamp, block.timestamp, uint80(0)));
        }

        if (!timeBased) {

            // should revert because oracle and pool price are different
            vm.expectRevert(IErrors.PriceDifferenceExceeded.selector);
            (debt, fullValue,collateralValue,liquidationCost,liquidationValue) = vault.loanInfo(TEST_NFT);

            // ignore difference - now it will work
            oracle.setMaxPoolPriceDifference(10001);
        }

        // debt is greater than collateral value
        (debt, fullValue,collateralValue,liquidationCost,liquidationValue) = vault.loanInfo(TEST_NFT);

        // debt only grows in time based scenario
        assertEq(debt, timeBased ? 8869647 : 8847206);

        // collateral value is lower in non time based scenario
        assertEq(collateralValue, timeBased ? 8847206 : 8492999);
        assertEq(fullValue, timeBased ? 9830229 : 9436666);

        assertGt(debt, collateralValue);
        assertEq(liquidationCost, timeBased ? 8869647 : 8492999);
        assertEq(liquidationValue, timeBased ? 9226564 : 9436666);

        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), liquidationCost - 1);

        (uint debtShares,) = vault.loans(TEST_NFT);

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vault.liquidate(IVault.LiquidateParams(TEST_NFT, debtShares, 0, 0, WHALE_ACCOUNT));

        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), liquidationCost);

        uint daiBalance = DAI.balanceOf(WHALE_ACCOUNT);
        uint usdcBalance = USDC.balanceOf(WHALE_ACCOUNT);


        vm.prank(WHALE_ACCOUNT);
        vault.liquidate(IVault.LiquidateParams(TEST_NFT, debtShares, 0, 0, WHALE_ACCOUNT));

        // DAI and USDC where sent to liquidator
        assertEq(DAI.balanceOf(WHALE_ACCOUNT) - daiBalance, timeBased ? 381693758226627942 : 393607068547774684);
        assertEq(USDC.balanceOf(WHALE_ACCOUNT) + liquidationCost - usdcBalance, timeBased ? 8844913 : 9436666);

        //  NFT was returned to owner
        assertEq(NPM.ownerOf(TEST_NFT), TEST_NFT_ACCOUNT);

        // all debt is payed
        assertEq(vault.debtSharesTotal(), 0);

        // protocol is solvent
        assertEq(USDC.balanceOf(address(vault)), timeBased ? 10022441 : 9645793);
        (,uint lent,uint balance,,,,) = vault.vaultInfo();
        assertEq(lent, timeBased ? 10022441 : 9645793);
        assertEq(balance, timeBased ? 10022441 : 9645793);

        // there maybe some amounts left in position
        (,,,, uint256 amount0, uint256 amount1,,) = oracle.getPositionBreakdown(TEST_NFT);
        assertEq(amount0, timeBased ? 11913310321146741 : 0);
        assertEq(amount1, timeBased ? 591753 : 0);

    }

    function testLiquidationWithFlashloan() external {

        _setupBasicLoan(true);

        // wait 7 day - interest growing
        vm.warp(block.timestamp + 7 days);

        // debt is greater than collateral value
        (uint debt,,,uint liquidationCost, uint liquidationValue) = vault.loanInfo(TEST_NFT);

        assertEq(debt, 8869647);
        assertEq(liquidationCost, 8869647);
        assertEq(liquidationValue, 9226564);

        (address token0, address token1,,,,,,) = oracle.getPositionBreakdown(TEST_NFT);

        uint token0Before = IERC20(token0).balanceOf(address(this));
        uint token1Before = IERC20(token1).balanceOf(address(this));
       
        FlashloanLiquidator liquidator = new FlashloanLiquidator(NPM, EX0x, UNIVERSAL_ROUTER);

        // available from liquidation (from static call to liquidate())
        uint amount0 = 381693758226627942;

        // universalrouter swap data (single swap command) - swap available DAI to USDC - and sweep
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(address(liquidator), amount0, 0, abi.encodePacked(token0, uint24(500), token1), false);
        inputs[1] = abi.encode(token0, address(liquidator), 0);
        bytes memory swapData0 = abi.encode(UNIVERSAL_ROUTER, abi.encode(Swapper.UniversalRouterData(hex"0004", inputs, block.timestamp)));

        (uint debtShares,) = vault.loans(TEST_NFT);

        vm.expectRevert(IErrors.NotEnoughReward.selector);
        liquidator.liquidate(FlashloanLiquidator.LiquidateParams(TEST_NFT, debtShares, vault, IUniswapV3Pool(UNISWAP_DAI_USDC), amount0, swapData0, 0, "", 356029));

        liquidator.liquidate(FlashloanLiquidator.LiquidateParams(TEST_NFT, debtShares, vault, IUniswapV3Pool(UNISWAP_DAI_USDC), amount0, swapData0, 0, "", 356028));

        vm.expectRevert(IErrors.NotLiquidatable.selector);
        liquidator.liquidate(FlashloanLiquidator.LiquidateParams(TEST_NFT, debtShares, vault, IUniswapV3Pool(UNISWAP_DAI_USDC), 0, "", 0, "", 0));

        assertEq(liquidationValue - liquidationCost, 356917); // promised liquidation premium

        assertEq(IERC20(token0).balanceOf(address(this)) - token0Before, 0);
        assertEq(IERC20(token1).balanceOf(address(this)) - token1Before, 356028); // actual liquidation premium (less because of swap)
        
        (debt,,,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 0);

        //  NFT was returned to owner
        assertEq(NPM.ownerOf(TEST_NFT), TEST_NFT_ACCOUNT);
    }


    function testCollateralValueLimit() external {

        _setupBasicLoan(false);
        vault.setTokenConfig(address(DAI), uint32(Q32 * 9 / 10), uint32(Q32 / 10)); // max 10% debt for DAI

        (,,uint totalDebtShares) = vault.tokenConfigs(address(DAI));
        assertEq(totalDebtShares, 0);
        (,,totalDebtShares) = vault.tokenConfigs(address(USDC));
        assertEq(totalDebtShares, 0);

        // borrow certain amount works
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, 800000);

        (,,totalDebtShares) = vault.tokenConfigs(address(DAI));
        assertEq(totalDebtShares, 800000);
        (,,totalDebtShares) = vault.tokenConfigs(address(USDC));
        assertEq(totalDebtShares, 800000);

        // borrow more doesnt work anymore - because more than max value of collateral is used
        vm.expectRevert(IErrors.CollateralValueLimit.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, 200001);

        // repay all
        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(vault), 1100000);

        // get debt shares
        (uint debtShares,) = vault.loans(TEST_NFT);
        assertEq(debtShares, 800000);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.repay(TEST_NFT, debtShares, true);

        // collateral is removed
        (,,totalDebtShares) = vault.tokenConfigs(address(DAI));
        assertEq(totalDebtShares, 0);
        (,,totalDebtShares) = vault.tokenConfigs(address(USDC));
        assertEq(totalDebtShares, 0);
    }

    function testMainScenario() external {

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.debtSharesTotal(), 0);
        assertEq(vault.loanCount(TEST_NFT_ACCOUNT), 0);

        // lending 2 USDC
        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 2000000);

        vm.prank(WHALE_ACCOUNT);
        vault.deposit(2000000, WHALE_ACCOUNT);
        assertEq(vault.totalSupply(), 2000000);

        // withdrawing 1 USDC
        vm.prank(WHALE_ACCOUNT);
        vault.withdraw(1000000, WHALE_ACCOUNT, WHALE_ACCOUNT);

        assertEq(vault.totalSupply(), 1000000);

        // borrowing 1 USDC
        _createAndBorrow(TEST_NFT, TEST_NFT_ACCOUNT, 1000000);
        assertEq(USDC.balanceOf(TEST_NFT_ACCOUNT), 1000000);

        assertEq(vault.loanCount(TEST_NFT_ACCOUNT), 1);
        assertEq(vault.loanAtIndex(TEST_NFT_ACCOUNT, 0), TEST_NFT);
        assertEq(vault.ownerOf(TEST_NFT), TEST_NFT_ACCOUNT);

        // gift some USDC so later he may repay all
        vm.prank(WHALE_ACCOUNT);
        USDC.transfer(TEST_NFT_ACCOUNT, 4946);

        assertEq(vault.debtSharesTotal(), 1000000);

        // wait 7 days
        vm.warp(block.timestamp + 7 days);

        // verify to date values
        (uint debt, uint fullValue, uint collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 1004945);
        assertEq(fullValue, 9830229);
        assertEq(collateralValue, 8847206);
        uint lent = vault.lendInfo(WHALE_ACCOUNT);
        assertEq(lent, 1004944);

        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(vault), 1004946);

        // repay partially       
        vm.prank(TEST_NFT_ACCOUNT);
        vault.repay(TEST_NFT, 1000000, false);
        (debt,,,,) = vault.loanInfo(TEST_NFT);
        (uint debtShares,) = vault.loans(TEST_NFT);
        assertEq(debtShares, 4921);
        assertEq(NPM.ownerOf(TEST_NFT), address(vault));
        assertEq(debt, 4946);

        // repay full  
        vm.prank(TEST_NFT_ACCOUNT);
        vault.repay(TEST_NFT, debtShares, true);

        (debt,,,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 0);
        assertEq(NPM.ownerOf(TEST_NFT), TEST_NFT_ACCOUNT);
        assertEq(vault.ownerOf(TEST_NFT), address(0));

        assertEq(vault.loanCount(TEST_NFT_ACCOUNT), 0);
    }

    function testMultiLendLoan() external {

        _deposit(2000000, WHALE_ACCOUNT);
        _deposit(1000000, TEST_NFT_ACCOUNT_2);

        // gift some USDC so later he may repay all
        vm.prank(WHALE_ACCOUNT);
        USDC.transfer(TEST_NFT_ACCOUNT, 1000000);

        _createAndBorrow(TEST_NFT, TEST_NFT_ACCOUNT, 1000000);
        _createAndBorrow(TEST_NFT_2, TEST_NFT_ACCOUNT_2, 2000000);

        assertEq(vault.balanceOf(WHALE_ACCOUNT), 2000000);
        assertEq(vault.balanceOf(TEST_NFT_ACCOUNT_2), 1000000);

        // wait 7 days (should generate around 0.49%)
        vm.warp(block.timestamp + 7 days);

        _deposit(1000000, TEST_NFT_ACCOUNT_2);
        assertEq(vault.balanceOf(TEST_NFT_ACCOUNT_2), 1995079); // less shares because more valuable

        // whale won double interest
        assertEq(vault.lendInfo(WHALE_ACCOUNT), 2009889);
        assertEq(vault.lendInfo(TEST_NFT_ACCOUNT_2), 2004943);

        // repay debts
        (uint debt,,,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 1004945);        
        _repay(debt, TEST_NFT_ACCOUNT, TEST_NFT, true);

        (debt,,,,) = vault.loanInfo(TEST_NFT_2);
        assertEq(debt, 2009890);
        _repay(debt, TEST_NFT_ACCOUNT_2, TEST_NFT_2, true);

        // withdraw shares
        uint shares = vault.balanceOf(WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        vault.redeem(shares, WHALE_ACCOUNT, WHALE_ACCOUNT);

        shares = vault.balanceOf(TEST_NFT_ACCOUNT_2);
        vm.prank(TEST_NFT_ACCOUNT_2);
        vault.redeem(shares, TEST_NFT_ACCOUNT_2, TEST_NFT_ACCOUNT_2);

        // check remaining 
        assertEq(USDC.balanceOf(address(vault)), 3);

        uint lent;
        uint balance;
        uint available;
        uint reserves;
        (debt,lent,balance,available,reserves,,) = vault.vaultInfo();
        assertEq(debt, 0);
        assertEq(lent, 0);
        assertEq(balance, 3);
        assertEq(available, 0);
        assertEq(reserves, 3);
        assertEq(USDC.balanceOf(address(vault)), 3);

        // get all out
        vault.withdrawReserves(reserves, address(this));

        (debt,lent,balance,available,reserves,,) = vault.vaultInfo();
        
        assertEq(debt, 0);
        assertEq(lent, 0);
        assertEq(balance, 0);
        assertEq(available, 0);
        assertEq(reserves, 0);
        assertEq(USDC.balanceOf(address(vault)), 0);
    }

    function testEmergencyAdmin() external {
        vm.expectRevert(IErrors.Unauthorized.selector);
        vm.prank(WHALE_ACCOUNT);
        vault.setLimits(0, 0, 0, 0, 0);

        vault.setEmergencyAdmin(WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        vault.setLimits(0, 0, 0, 0, 0);
    }
}