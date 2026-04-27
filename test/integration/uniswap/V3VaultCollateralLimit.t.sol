// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/InterestRateModel.sol";
import "../../../src/V3Oracle.sol";
import "../../../src/V3Vault.sol";
import "../../../src/utils/Constants.sol";

contract V3VaultCollateralLimitForkTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address constant UNISWAP_DAI_USDC = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168;
    address constant UNISWAP_ETH_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    address constant TEST_NFT_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    uint256 constant TEST_NFT = 126;

    V3Vault internal vault;
    InterestRateModel internal interestRateModel;
    V3Oracle internal oracle;

    function setUp() external {
        string memory rpc = string.concat("https://rpc.ankr.com/eth/", vm.envString("ANKR_API_KEY"));
        vm.createSelectFork(rpc, 18521658);

        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

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
            50000
        );
        oracle.setTokenConfig(
            address(WETH),
            AggregatorV3Interface(CHAINLINK_ETH_USD),
            3600 * 24 * 30,
            IUniswapV3Pool(UNISWAP_ETH_USDC),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            50000
        );

        vault = new V3Vault("Revert Lend USDC", "rlUSDC", address(USDC), NPM, interestRateModel, oracle);

        uint32 limitFactor = uint32(Q32 / 2);
        vault.setTokenConfig(address(USDC), uint32(Q32 * 9 / 10), limitFactor);
        vault.setTokenConfig(address(DAI), uint32(Q32 * 9 / 10), limitFactor);
        vault.setTokenConfig(address(WETH), uint32(Q32 * 9 / 10), limitFactor);

        vault.setLimits(0, 100_000_000, 100_000_000, 100_000_000, 100_000_000);
        vault.setReserveFactor(0);

        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 10_000_000);
        vm.prank(WHALE_ACCOUNT);
        vault.deposit(10_000_000, WHALE_ACCOUNT);
    }

    function testCollateralValueLimitCannotBeBypassedViaMulticallDepositSandwich() external {
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        (, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertGt(fullValue, 0);
        assertGt(collateralValue, 6_000_000);

        vm.expectRevert(Constants.CollateralValueLimit.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, 6_000_000);

        uint256 flashDepositAmount = 50_000_000;
        vm.prank(WHALE_ACCOUNT);
        USDC.transfer(TEST_NFT_ACCOUNT, flashDepositAmount);

        vm.startPrank(TEST_NFT_ACCOUNT);
        USDC.approve(address(vault), flashDepositAmount);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(V3Vault.deposit, (flashDepositAmount, TEST_NFT_ACCOUNT));
        calls[1] = abi.encodeCall(V3Vault.borrow, (TEST_NFT, 6_000_000));
        calls[2] = abi.encodeCall(V3Vault.withdraw, (flashDepositAmount, TEST_NFT_ACCOUNT, TEST_NFT_ACCOUNT));

        vm.expectRevert(Constants.CollateralValueLimit.selector);
        vault.multicall(calls);
        vm.stopPrank();

        (uint256 debtShares) = vault.loans(TEST_NFT);
        assertEq(debtShares, 0, "bypass attempt must not leave residual debt");
    }
}
