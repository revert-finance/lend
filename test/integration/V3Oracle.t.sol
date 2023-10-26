// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/V3Oracle.sol";
import "../../src/Vault.sol";

contract V3OracleIntegrationTest is Test {
   
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

    uint256 constant TEST_NFT = 126; // DAI/USDC 0.05% - in range (-276330/-276320)
    uint256 constant TEST_NFT_UNI = 1; // WETH/UNI 0.3%

    uint256 mainnetFork;

    Vault vault;
    InterestRateModel interestRateModel;
    V3Oracle oracle;

    function setUp() external {

        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);

        interestRateModel = new InterestRateModel();

        oracle = new V3Oracle(NPM, address(USDC), address(0));
        oracle.setTokenConfig(address(USDC), AggregatorV3Interface(CHAINLINK_USDC_USD), 3600 * 48, IUniswapV3Pool(address(0)), 0, V3Oracle.Mode.TWAP, 0);
        oracle.setTokenConfig(address(DAI), AggregatorV3Interface(CHAINLINK_DAI_USD), 3600 * 48, IUniswapV3Pool(UNISWAP_DAI_USDC), 60, V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, 500);
        oracle.setTokenConfig(address(WETH), AggregatorV3Interface(CHAINLINK_ETH_USD), 3600, IUniswapV3Pool(UNISWAP_ETH_USDC), 60, V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, 500);

        vault = new Vault(NPM, USDC, interestRateModel, oracle);
        vault.setTokenConfig(address(USDC), uint32(2 ** 32 * 9 / 10)); //90%
        vault.setTokenConfig(address(DAI), uint32(2 ** 32 * 9 / 10)); //80%
        vault.setTokenConfig(address(WETH), uint32(2 ** 32 * 8 / 10)); //80%
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