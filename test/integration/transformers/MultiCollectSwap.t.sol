// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../../src/V3Oracle.sol";
import "../../../src/V3Vault.sol";
import "../../../src/InterestRateModel.sol";
import "../../../src/transformers/MultiCollectSwap.sol";
import "../../../src/utils/Constants.sol";

contract MultiCollectSwapTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;
    address UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address constant UNISWAP_DAI_USDC = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168;
    address constant UNISWAP_ETH_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    // DAI/USDC 0.05% - in range - with liquidity and fees
    uint256 constant TEST_NFT = 126;
    address constant TEST_NFT_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;

    // Another DAI/USDC position with fees
    uint256 constant TEST_NFT_2 = 1047;
    address constant TEST_NFT_2_ACCOUNT = 0x454CE089a879F7A0d0416eddC770a47A1F47Be99;

    // DAI/USDC position with fees
    uint256 constant TEST_NFT_3 = 4660;
    address constant TEST_NFT_3_ACCOUNT = 0xa3eF006a7da5BcD1144d8BB86EfF1734f46A0c1E;

    uint256 mainnetFork;

    V3Vault vault;
    InterestRateModel interestRateModel;
    V3Oracle oracle;
    MultiCollectSwap multiCollectSwap;

    function setUp() external {
        string memory ANKR_RPC = string.concat("https://rpc.ankr.com/eth/", vm.envString("ANKR_API_KEY"));
        mainnetFork = vm.createFork(ANKR_RPC, 18521658);
        vm.selectFork(mainnetFork);

        // Setup oracle
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

        // Setup interest rate model
        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

        // Setup vault
        vault =
            new V3Vault("Revert Lend USDC", "rlUSDC", address(USDC), NPM, interestRateModel, oracle, IPermit2(PERMIT2));
        vault.setTokenConfig(address(USDC), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(DAI), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(WETH), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setLimits(0, 15000000, 15000000, 12000000, 12000000);
        vault.setReserveFactor(0);

        // Setup MultiCollectSwap
        multiCollectSwap = new MultiCollectSwap(NPM, UNIVERSAL_ROUTER, EX0x);
        multiCollectSwap.setVault(address(vault));
        vault.setTransformer(address(multiCollectSwap), true);
    }

    function testDirectCollectWithoutSwaps() external {
        // User collects from their directly owned position
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TEST_NFT;

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        uint256 daiBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);
        uint256 usdcBefore = USDC.balanceOf(TEST_NFT_ACCOUNT);

        // Approve the MultiCollectSwap contract
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(multiCollectSwap), true);

        // Execute collect - using DAI as output token since position has DAI/USDC
        vm.prank(TEST_NFT_ACCOUNT);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: TEST_NFT_ACCOUNT
            })
        );

        uint256 daiAfter = DAI.balanceOf(TEST_NFT_ACCOUNT);
        uint256 usdcAfter = USDC.balanceOf(TEST_NFT_ACCOUNT);

        // Should have collected some fees (DAI is output token)
        assertGe(daiAfter, daiBefore);
        // USDC collected stays in contract since no swaps defined and it's not the output token
        assertEq(usdcAfter, usdcBefore);
    }

    function testMultipleDirectCollects() external {
        // Collect from two positions owned by different accounts
        // First transfer TEST_NFT to TEST_NFT_3_ACCOUNT so they own both
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.transferFrom(TEST_NFT_ACCOUNT, TEST_NFT_3_ACCOUNT, TEST_NFT);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TEST_NFT;
        tokenIds[1] = TEST_NFT_3;

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        uint256 daiBefore = DAI.balanceOf(TEST_NFT_3_ACCOUNT);

        vm.prank(TEST_NFT_3_ACCOUNT);
        NPM.setApprovalForAll(address(multiCollectSwap), true);

        vm.prank(TEST_NFT_3_ACCOUNT);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: TEST_NFT_3_ACCOUNT
            })
        );

        uint256 daiAfter = DAI.balanceOf(TEST_NFT_3_ACCOUNT);
        assertGt(daiAfter, daiBefore);
    }

    function testVaultCollectWithoutSwaps() external {
        // Setup: deposit liquidity and create a loan with the position in vault
        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 10000000);
        vm.prank(WHALE_ACCOUNT);
        vault.deposit(10000000, WHALE_ACCOUNT);

        // Put position into vault
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        // Approve transform for multiCollectSwap
        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(multiCollectSwap), true);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TEST_NFT;

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        uint256 daiBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);

        // Execute collect via vault transform
        vm.prank(TEST_NFT_ACCOUNT);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: TEST_NFT_ACCOUNT
            })
        );

        uint256 daiAfter = DAI.balanceOf(TEST_NFT_ACCOUNT);
        assertGt(daiAfter, daiBefore);
    }

    function testMixedVaultAndDirectCollect() external {
        // Setup vault with one position
        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 10000000);
        vm.prank(WHALE_ACCOUNT);
        vault.deposit(10000000, WHALE_ACCOUNT);

        // Put TEST_NFT into vault
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        // Approve transform
        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(multiCollectSwap), true);

        // Transfer TEST_NFT_3 to TEST_NFT_ACCOUNT so they own both
        vm.prank(TEST_NFT_3_ACCOUNT);
        NPM.transferFrom(TEST_NFT_3_ACCOUNT, TEST_NFT_ACCOUNT, TEST_NFT_3);

        // Approve NPM for direct position
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(multiCollectSwap), true);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TEST_NFT; // In vault
        tokenIds[1] = TEST_NFT_3; // Direct ownership

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        uint256 daiBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: TEST_NFT_ACCOUNT
            })
        );

        uint256 daiAfter = DAI.balanceOf(TEST_NFT_ACCOUNT);
        assertGt(daiAfter, daiBefore);
    }

    function testUnauthorizedDirectCollect() external {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TEST_NFT;

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        // Try to collect from position we don't own
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: WHALE_ACCOUNT
            })
        );
    }

    function testUnauthorizedVaultCollectNoTransformApproval() external {
        // Setup vault with position
        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 10000000);
        vm.prank(WHALE_ACCOUNT);
        vault.deposit(10000000, WHALE_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        // Don't approve transform - should fail

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TEST_NFT;

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        // Try to collect without transform approval - should fail
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: TEST_NFT_ACCOUNT
            })
        );
    }

    function testUnauthorizedVaultCollectThirdParty() external {
        // Setup vault with position and approve transform
        vm.prank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 10000000);
        vm.prank(WHALE_ACCOUNT);
        vault.deposit(10000000, WHALE_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        // Owner approves transform
        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(multiCollectSwap), true);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TEST_NFT;

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        // Third party (WHALE_ACCOUNT) tries to collect - should fail even though transform is approved
        // This tests the security fix: caller must be the vault position owner
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: WHALE_ACCOUNT
            })
        );
    }

    function testCollectCalledDirectly() external {
        // collect() should only be callable by vault via transform
        // When called directly by someone who doesn't own the position and isn't a vault,
        // it should revert with Unauthorized
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        multiCollectSwap.collect(TEST_NFT);
    }

    function testEmptyTokenIds() external {
        uint256[] memory tokenIds = new uint256[](0);
        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        // Should succeed with empty arrays (no-op)
        vm.prank(TEST_NFT_ACCOUNT);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: TEST_NFT_ACCOUNT
            })
        );
    }

    function testDifferentRecipient() external {
        address recipient = address(0x1234);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TEST_NFT;

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(multiCollectSwap), true);

        uint256 daiBefore = DAI.balanceOf(recipient);

        vm.prank(TEST_NFT_ACCOUNT);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: recipient
            })
        );

        uint256 daiAfter = DAI.balanceOf(recipient);
        // Fees are sent to the specified recipient
        assertGe(daiAfter, daiBefore);
    }

    function testDirectCollectWithSingleApproval() external {
        // Test using NPM.approve() for single token instead of setApprovalForAll()
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TEST_NFT;

        Swapper.RouterSwapParams[] memory swaps = new Swapper.RouterSwapParams[](0);

        uint256 daiBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);

        // Approve only the specific token (not all tokens)
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(multiCollectSwap), TEST_NFT);

        vm.prank(TEST_NFT_ACCOUNT);
        multiCollectSwap.execute(
            MultiCollectSwap.ExecuteParams({
                tokenIds: tokenIds,
                swaps: swaps,
                outputToken: address(DAI),
                recipient: TEST_NFT_ACCOUNT
            })
        );

        uint256 daiAfter = DAI.balanceOf(TEST_NFT_ACCOUNT);
        assertGe(daiAfter, daiBefore);
    }
}
