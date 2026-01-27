// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/V3Oracle.sol";
import "../../../src/V3Vault.sol";
import "../../../src/InterestRateModel.sol";
import "../../../src/transformers/LeverageTransformer.sol";
import "../../../src/utils/Constants.sol";

contract LeverageTransformerTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;
    address UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address constant UNISWAP_DAI_USDC = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168;
    address constant UNISWAP_ETH_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    address constant TEST_NFT_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    uint256 constant TEST_NFT = 126; // DAI/USDC 0.05%

    uint256 mainnetFork;

    V3Vault vault;
    InterestRateModel interestRateModel;
    V3Oracle oracle;
    LeverageTransformer leverageTransformer;

    function setUp() external {
        string memory ANKR_RPC = string.concat(
            "https://rpc.ankr.com/eth/",
            vm.envString("ANKR_API_KEY")
        );
        mainnetFork = vm.createFork(ANKR_RPC, 18521658);
        vm.selectFork(mainnetFork);

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

        vault = new V3Vault("Revert Lend USDC", "rlUSDC", address(USDC), NPM, interestRateModel, oracle, IPermit2(PERMIT2));
        vault.setTokenConfig(address(USDC), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(DAI), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(WETH), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setLimits(0, 15000000, 15000000, 12000000, 12000000);
        vault.setReserveFactor(0);

        // Setup LeverageTransformer
        leverageTransformer = new LeverageTransformer(NPM, EX0x, UNIVERSAL_ROUTER);
        vault.setTransformer(address(leverageTransformer), true);
        leverageTransformer.setVault(address(vault));
    }

    function _setupLoan() internal {
        // Deposit liquidity
        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 10000000);
        vm.prank(WHALE_ACCOUNT);
        vault.deposit(10000000, WHALE_ACCOUNT);

        // Create position in vault
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);
    }

    /// @notice Test that leverageUp reverts when called directly by an EOA (not through vault.transform)
    function testLeverageUpDirectCallReverts() external {
        _setupLoan();

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            tokenId: TEST_NFT,
            borrowAmount: 1000000,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 0,
            amountAddMin1: 0,
            recipient: TEST_NFT_ACCOUNT,
            deadline: block.timestamp
        });

        // Direct call should revert with Unauthorized because msg.sender is not a whitelisted vault
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        leverageTransformer.leverageUp(params);
    }

    /// @notice Test that leverageDown reverts when called directly by an EOA (not through vault.transform)
    function testLeverageDownDirectCallReverts() external {
        _setupLoan();

        // First borrow some amount so we have debt to leverage down
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, 1000000);

        LeverageTransformer.LeverageDownParams memory params = LeverageTransformer.LeverageDownParams({
            tokenId: TEST_NFT,
            liquidity: 1,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            feeAmount0: 0,
            feeAmount1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            recipient: TEST_NFT_ACCOUNT,
            deadline: block.timestamp
        });

        // Direct call should revert with Unauthorized because msg.sender is not a whitelisted vault
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        leverageTransformer.leverageDown(params);
    }

    /// @notice Test that leverageDown works when called through vault.transform
    function testLeverageDownThroughVaultWorks() external {
        _setupLoan();

        // First borrow some amount
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, 1000000);

        (uint256 debtBefore,,,,) = vault.loanInfo(TEST_NFT);
        assertEq(debtBefore, 1000000);

        LeverageTransformer.LeverageDownParams memory params = LeverageTransformer.LeverageDownParams({
            tokenId: TEST_NFT,
            liquidity: 1000000000000000, // Remove some liquidity
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            feeAmount0: type(uint128).max,
            feeAmount1: type(uint128).max,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            recipient: TEST_NFT_ACCOUNT,
            deadline: block.timestamp
        });

        // Call through vault.transform should work
        vm.prank(TEST_NFT_ACCOUNT);
        vault.transform(
            TEST_NFT,
            address(leverageTransformer),
            abi.encodeWithSelector(LeverageTransformer.leverageDown.selector, params)
        );

        // Verify some debt was repaid
        (uint256 debtAfter,,,,) = vault.loanInfo(TEST_NFT);
        assertLt(debtAfter, debtBefore);
    }

    /// @notice Test that leverageUp reverts when called by a non-whitelisted contract
    function testLeverageUpFromNonWhitelistedContractReverts() external {
        _setupLoan();

        // Create a second vault that is NOT whitelisted in leverageTransformer
        V3Vault vault2 = new V3Vault("Revert Lend USDC 2", "rlUSDC2", address(USDC), NPM, interestRateModel, oracle, IPermit2(PERMIT2));
        vault2.setTokenConfig(address(USDC), uint32(Q32 * 9 / 10), type(uint32).max);
        vault2.setTokenConfig(address(DAI), uint32(Q32 * 9 / 10), type(uint32).max);
        vault2.setLimits(0, 15000000, 15000000, 12000000, 12000000);
        vault2.setTransformer(address(leverageTransformer), true);
        // Note: leverageTransformer.setVault(address(vault2)) is NOT called

        // Setup loan in vault2
        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault2), 10000000);
        vm.prank(WHALE_ACCOUNT);
        vault2.deposit(10000000, WHALE_ACCOUNT);

        // Transfer NFT from vault to owner first, then to vault2
        vm.prank(TEST_NFT_ACCOUNT);
        vault.remove(TEST_NFT, TEST_NFT_ACCOUNT, "");

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault2), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault2.create(TEST_NFT, TEST_NFT_ACCOUNT);

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            tokenId: TEST_NFT,
            borrowAmount: 1000000,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 0,
            amountAddMin1: 0,
            recipient: TEST_NFT_ACCOUNT,
            deadline: block.timestamp
        });

        // Call through non-whitelisted vault2 should fail because vault2 is not in leverageTransformer.vaults
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(Constants.TransformFailed.selector);
        vault2.transform(
            TEST_NFT,
            address(leverageTransformer),
            abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params)
        );
    }
}
