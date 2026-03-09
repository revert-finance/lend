// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// base contracts
import "../../../src/V3Oracle.sol";
import "v3-core/interfaces/pool/IUniswapV3PoolDerivedState.sol";

import "../../../src/utils/Constants.sol";

contract MockSequencerFeed is AggregatorV3Interface {
    int256 public answer;
    uint256 public startedAt;

    constructor(int256 _answer, uint256 _startedAt) {
        answer = _answer;
        startedAt = _startedAt;
    }

    function setStatus(int256 _answer, uint256 _startedAt) external {
        answer = _answer;
        startedAt = _startedAt;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 _answer, uint256 _startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, answer, startedAt, block.timestamp, 1);
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }
}

contract V3OracleIntegrationTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q96 = 2 ** 96;

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

    uint256 constant TEST_NFT = 126; // DAI/USDC 0.05% - in range (-276330/-276320)

    uint256 constant TEST_NFT_UNI = 1; // WETH/UNI 0.3%

    uint256 constant TEST_NFT_DAI_WETH = 548468; // DAI/WETH 0.05%

    uint256 mainnetFork;
    V3Oracle oracle;

    function setUp() external {
          string memory ANKR_RPC = string.concat(
            "https://rpc.ankr.com/eth/",
            vm.envString("ANKR_API_KEY")
        );
        mainnetFork = vm.createFork(ANKR_RPC, 18521658);
        vm.selectFork(mainnetFork);

        // use tolerant oracles (so timewarp for until 30 days works in tests - also allow divergence from price for mocked price results)
        oracle = new V3Oracle(NPM, address(USDC), address(0));
        oracle.setMaxPoolPriceDifference(200);
        oracle.setTokenConfig(
            address(USDC),
            AggregatorV3Interface(CHAINLINK_USDC_USD),
            3600 * 24 * 30,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.TWAP,
            0
        );
        oracle.setTokenConfig(
            address(DAI),
            AggregatorV3Interface(CHAINLINK_DAI_USD),
            3600 * 24 * 30,
            IUniswapV3Pool(UNISWAP_DAI_USDC),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            address(WETH),
            AggregatorV3Interface(CHAINLINK_ETH_USD),
            3600 * 24 * 30,
            IUniswapV3Pool(UNISWAP_ETH_USDC),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
    }

    function testConversionChainlink() external {
        (uint256 valueUSDC,,,) = oracle.getValue(TEST_NFT, address(USDC), false);
        assertEq(valueUSDC, 9829088);

        (uint256 valueDAI,,,) = oracle.getValue(TEST_NFT, address(DAI), false);
        assertEq(valueDAI, 9830164473705245040);

        (uint256 valueWETH,,,) = oracle.getValue(TEST_NFT, address(WETH), false);
        assertEq(valueWETH, 5264700508440484);
    }

    function testChainlinkOnlyConfigSupportsTokenValueWithoutPool() external {
        V3Oracle chainlinkOnlyOracle = new V3Oracle(NPM, address(USDC), address(0));
        chainlinkOnlyOracle.setTokenConfig(
            address(USDC),
            AggregatorV3Interface(CHAINLINK_USDC_USD),
            3600 * 24 * 30,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );
        chainlinkOnlyOracle.setTokenConfig(
            address(DAI),
            AggregatorV3Interface(CHAINLINK_DAI_USD),
            3600 * 24 * 30,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );

        uint256 daiValueInUsdc = chainlinkOnlyOracle.getTokenValue(address(DAI), 1e18, address(USDC));
        assertGt(daiValueInUsdc, 0);
    }

    function testGetValueIgnoreFeesSkipsFeeValue() external {
        (uint256 valueWithFees, uint256 feeValueWithFees, uint256 price0WithFees, uint256 price1WithFees) =
            oracle.getValue(TEST_NFT, address(USDC), false);
        (uint256 valueIgnoreFees, uint256 feeValueIgnoreFees, uint256 price0IgnoreFees, uint256 price1IgnoreFees) =
            oracle.getValue(TEST_NFT, address(USDC), true);

        assertEq(feeValueIgnoreFees, 0);
        assertEq(price0IgnoreFees, price0WithFees);
        assertEq(price1IgnoreFees, price1WithFees);
        assertLe(valueIgnoreFees, valueWithFees);
        if (feeValueWithFees != 0) {
            assertLt(valueIgnoreFees, valueWithFees);
        }
    }

    function testConversionTWAP() external {
        oracle.setOracleMode(address(USDC), V3Oracle.Mode.TWAP_CHAINLINK_VERIFY);
        oracle.setOracleMode(address(DAI), V3Oracle.Mode.TWAP_CHAINLINK_VERIFY);
        oracle.setOracleMode(address(WETH), V3Oracle.Mode.TWAP_CHAINLINK_VERIFY);

        (uint256 valueUSDC,,,) = oracle.getValue(TEST_NFT, address(USDC), false);
        assertEq(valueUSDC, 9829593);

        (uint256 valueDAI,,,) = oracle.getValue(TEST_NFT, address(DAI), false);
        assertEq(valueDAI, 9829567935538784710);

        (uint256 valueWETH,,,) = oracle.getValue(TEST_NFT, address(WETH), false);
        assertEq(valueWETH, 5253670438160606);

        (uint256 valueUSDC2,, uint256 price0, uint256 price1) = oracle.getValue(TEST_NFT_DAI_WETH, address(USDC), false);
        assertEq(valueUSDC2, 57217647627);

        assertEq(price0, 79228371980132557);
        assertEq(price1, 148235538176146811595);

        (,,,, uint256 amount0, uint256 amount1,,) = oracle.getPositionBreakdown(TEST_NFT_DAI_WETH);
        assertEq(amount0, 29754721813133755549897);
        assertEq(amount1, 14500423413066020069);
    }

    function testNonExistingToken() external {
        vm.expectRevert(Constants.NotConfigured.selector);
        oracle.getValue(TEST_NFT, address(WBTC), false);

        vm.expectRevert(Constants.NotConfigured.selector);
        oracle.getValue(TEST_NFT_UNI, address(WETH), false);
    }

    function testInvalidPoolConfig() external {
        vm.expectRevert(Constants.InvalidPool.selector);
        oracle.setTokenConfig(
            address(WETH),
            AggregatorV3Interface(CHAINLINK_ETH_USD),
            3600,
            IUniswapV3Pool(UNISWAP_DAI_USDC),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            500
        );
    }

    function testEmergencyAdmin() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(WHALE_ACCOUNT);
        oracle.setOracleMode(address(WETH), V3Oracle.Mode.TWAP_CHAINLINK_VERIFY);

        oracle.setEmergencyAdmin(WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        oracle.setOracleMode(address(WETH), V3Oracle.Mode.TWAP_CHAINLINK_VERIFY);
    }

    function testChainlinkError() external {
        vm.mockCall(
            CHAINLINK_DAI_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), int256(0), block.timestamp, block.timestamp, uint80(0))
        );
        vm.expectRevert(Constants.ChainlinkPriceError.selector);
        oracle.getValue(TEST_NFT, address(WETH), false);

        vm.mockCall(
            CHAINLINK_DAI_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), int256(1), uint256(0), uint256(0), uint80(0))
        );
        vm.expectRevert(Constants.ChainlinkPriceError.selector);
        oracle.getValue(TEST_NFT, address(WETH), false);
    }

    function testPriceDivergence() external {
        // change call to simulate oracle difference in chainlink
        vm.mockCall(
            CHAINLINK_DAI_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), int256(1), block.timestamp, block.timestamp, uint80(0))
        );

        vm.expectRevert(Constants.PriceDifferenceExceeded.selector);
        oracle.getValue(TEST_NFT, address(WETH), false);

        // works with normal prices
        vm.clearMockedCalls();
        (uint256 valueWETH,,,) = oracle.getValue(TEST_NFT, address(WETH), false);
        assertEq(valueWETH, 5264700508440484);

        // change call to simulate oracle difference in univ3 twap
        int56[] memory tickCumulatives = new int56[](2);
        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        vm.mockCall(
            UNISWAP_DAI_USDC,
            abi.encodeWithSelector(IUniswapV3PoolDerivedState.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
        vm.expectRevert(Constants.PriceDifferenceExceeded.selector);
        oracle.getValue(TEST_NFT, address(WETH), false);
    }

    function testSequencerUptimeFeedChecks() external {
        MockSequencerFeed sequencerFeed = new MockSequencerFeed(0, block.timestamp - 1000);

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setSequencerUptimeFeed(address(sequencerFeed));

        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        assertEq(oracle.sequencerUptimeFeed(), address(sequencerFeed));

        sequencerFeed.setStatus(1, block.timestamp - 1000);
        vm.expectRevert(Constants.SequencerDown.selector);
        oracle.getValue(TEST_NFT, address(WETH), false);

        sequencerFeed.setStatus(0, 0);
        vm.expectRevert(Constants.SequencerUptimeFeedInvalid.selector);
        oracle.getValue(TEST_NFT, address(WETH), false);

        sequencerFeed.setStatus(0, block.timestamp - 100);
        vm.expectRevert(Constants.SequencerGracePeriodNotOver.selector);
        oracle.getValue(TEST_NFT, address(WETH), false);

        sequencerFeed.setStatus(0, block.timestamp - 1000);
        (uint256 value,,,) = oracle.getValue(TEST_NFT, address(WETH), false);
        assertGt(value, 0);
    }
}
