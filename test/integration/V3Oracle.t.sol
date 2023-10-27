// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/V3Oracle.sol";
import "../../src/Vault.sol";

contract V3OracleIntegrationTest is Test {
   
    uint constant Q32 = 2 ** 32;
    uint constant Q96 = 2 ** 96;

    uint constant YEAR_SECS = 31556925216; // taking into account leap years

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    IERC20 constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address constant UNISWAP_DAI_USDC = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168; // 0.01% pool
    address constant UNISWAP_ETH_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // 0.05% pool

    address constant TEST_NFT_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    uint256 constant TEST_NFT = 126; // DAI/USDC 0.05% - in range (-276330/-276320)

    uint256 constant TEST_NFT_UNI = 1; // WETH/UNI 0.3%

    uint256 mainnetFork;

    Vault vault;
    InterestRateModel interestRateModel;
    V3Oracle oracle;

    function setUp() external {

        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);

        // 5% base rate - after 80% - 109% (like in compound v2 deployed) 
        interestRateModel = new InterestRateModel(0, Q96 * 5 / 100, Q96 * 109 / 100, Q96 * 80 / 100);

        oracle = new V3Oracle(NPM, address(USDC), address(0));
        oracle.setTokenConfig(address(USDC), AggregatorV3Interface(CHAINLINK_USDC_USD), 3600 * 48, IUniswapV3Pool(address(0)), 0, V3Oracle.Mode.TWAP, 0);
        oracle.setTokenConfig(address(DAI), AggregatorV3Interface(CHAINLINK_DAI_USD), 3600 * 48, IUniswapV3Pool(UNISWAP_DAI_USDC), 60, V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, 500);
        oracle.setTokenConfig(address(WETH), AggregatorV3Interface(CHAINLINK_ETH_USD), 3600, IUniswapV3Pool(UNISWAP_ETH_USDC), 60, V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, 500);

        vault = new Vault(NPM, USDC, interestRateModel, oracle);
        vault.setTokenConfig(address(USDC), uint32(Q32 * 9 / 10)); //90%
        vault.setTokenConfig(address(DAI), uint32(Q32 * 9 / 10)); //80%
        vault.setTokenConfig(address(WETH), uint32(Q32 * 8 / 10)); //80%
    }

    function testMainScenario() external {

        // 10 USDC each (without reserve for now)
        vault.setLimits(10000000, 10000000);
        vault.setReserveFactor(0);
        vault.setReserveProtectionFactor(0);

        assertEq(vault.globalLendAmount(), 0);
        assertEq(vault.globalDebtAmount(), 0);

        // lending 2 USDC
        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 2000000);

        vm.prank(WHALE_ACCOUNT);
        vault.deposit(2000000);
        assertEq(vault.globalLendAmount(), 2000000);

        vm.warp(block.timestamp + 30 seconds);

        // withdrawing 1 USDC
        vm.prank(WHALE_ACCOUNT);
        vault.withdraw(1000000);

        vm.warp(block.timestamp + 30 seconds);

        assertEq(vault.globalLendAmount(), 1000000);

        // borrowing 1 USDC
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, 1000000);

        assertEq(vault.globalDebtAmount(), 1000000);

        // wait one day
        vm.warp(block.timestamp + 1 days);

        // values are static - ONLY updated after operation
        assertEq(vault.globalDebtAmount(), 1000000);
        assertEq(vault.globalLendAmount(), 1000000);
        vault.deposit(0);
        assertEq(vault.globalDebtAmount(), 1000000);
        assertEq(vault.globalLendAmount(), 1000000);

        // verify to date values
        (uint debt, uint fullValue, uint collateralValue) = vault.loanInfo(TEST_NFT);
        uint lent = vault.lendInfo(WHALE_ACCOUNT);
        assertEq(debt, 1000000);
        assertEq(fullValue, 9793851);
        assertEq(collateralValue, 8814465);
        assertEq(lent, 1000000);

        // repay 
        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(vault), 1);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.repay(TEST_NFT, 1);
    }



    function testUtilizationRates() external {
        assertEq(interestRateModel.getUtilizationRateX96(10, 0), 0);
        assertEq(interestRateModel.getUtilizationRateX96(10, 10), Q96 / 2);
        assertEq(interestRateModel.getUtilizationRateX96(0, 10), Q96);
    }

    function testInterestRates() external {
        assertEq(interestRateModel.getBorrowRatePerSecondX96(10, 0) * YEAR_SECS, 0); // 0% for 0% utilization
        assertEq(interestRateModel.getBorrowRatePerSecondX96(10000000, 10000000) * YEAR_SECS, 1980704062856608435230950304); // 2.5% per year for 50% utilization
        assertEq(interestRateModel.getBorrowRatePerSecondX96(0, 10) * YEAR_SECS, 20440865928680199049058853120); // 25.8% per year for 100% utilization
    }

    function testConversionChainlink() external {

        uint valueUSDC = oracle.getValue(TEST_NFT, address(USDC));
        assertEq(valueUSDC, 9793851);

        uint valueDAI = oracle.getValue(TEST_NFT, address(DAI));
        assertEq(valueDAI, 9788534213928977067);

        uint valueWETH = oracle.getValue(TEST_NFT, address(WETH));
        assertEq(valueWETH, 6450448054513969);
    }

    function testConversionTWAP() external {

        oracle.setOracleMode(address(USDC), V3Oracle.Mode.TWAP_CHAINLINK_VERIFY);
        oracle.setOracleMode(address(DAI), V3Oracle.Mode.TWAP_CHAINLINK_VERIFY);
        oracle.setOracleMode(address(WETH), V3Oracle.Mode.TWAP_CHAINLINK_VERIFY);

        uint valueUSDC = oracle.getValue(TEST_NFT, address(USDC));
        assertEq(valueUSDC, 9791272);

        uint valueDAI = oracle.getValue(TEST_NFT, address(DAI));
        assertEq(valueDAI, 9791246113600479299);

        uint valueWETH = oracle.getValue(TEST_NFT, address(WETH));
        assertEq(valueWETH, 6445681020772445);
    }

    function testNonExistingToken() external {
        vm.expectRevert(V3Oracle.NotConfiguredToken.selector);
        oracle.getValue(TEST_NFT, address(WBTC));

        vm.expectRevert(V3Oracle.NotConfiguredToken.selector);
        oracle.getValue(TEST_NFT_UNI, address(WETH));
    }

    function testInvalidPoolConfig() external {
        vm.expectRevert(V3Oracle.InvalidPool.selector);
        oracle.setTokenConfig(address(WETH), AggregatorV3Interface(CHAINLINK_ETH_USD), 3600, IUniswapV3Pool(UNISWAP_DAI_USDC), 60, V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, 500);
    }
}