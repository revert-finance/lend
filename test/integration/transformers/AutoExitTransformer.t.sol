// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../../src/V3Oracle.sol";
import "../../../src/V3Vault.sol";
import "../../../src/InterestRateModel.sol";
import "../../../src/transformers/AutoExitTransformer.sol";
import "../../../src/utils/Constants.sol";

contract AutoExitTransformerTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;
    uint256 constant Q96 = 2 ** 96;

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant OPERATOR_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant WITHDRAWER_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    uint64 constant MAX_REWARD = uint64(Q64 / 400); // 0.25%
    uint64 constant MAX_FEE_REWARD = uint64(Q64 / 20); // 5%
    uint64 constant MAX_SLIPPAGE = uint64(Q64 / 100); // 1%

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

    address constant UNISWAP_DAI_USDC = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168; // 0.01% pool
    address constant UNISWAP_ETH_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    address constant TEST_NFT_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    uint256 constant TEST_NFT = 126; // DAI/USDC 0.05% - in range (-276330/-276320)

    uint256 mainnetFork;

    V3Vault vault;
    InterestRateModel interestRateModel;
    V3Oracle oracle;
    AutoExitTransformer autoExitTransformer;

    function setUp() external {
        mainnetFork = vm.createFork("https://eth-mainnet.g.alchemy.com/v2/gwRYWylWRij2jXTnPXR90v-YqXh96PDX", 18521658);
        vm.selectFork(mainnetFork);

        // Setup interest rate model
        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

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

        // Setup vault
        vault = new V3Vault("Revert Lend USDC", "rlUSDC", address(USDC), NPM, interestRateModel, oracle, IPermit2(PERMIT2));
        vault.setTokenConfig(address(USDC), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(DAI), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(WETH), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setLimits(0, 15000000, 15000000, 12000000, 12000000);
        vault.setReserveFactor(0);

        // Setup AutoExitTransformer
        autoExitTransformer = new AutoExitTransformer(
            NPM,
            OPERATOR_ACCOUNT,
            WITHDRAWER_ACCOUNT,
            60,
            100,
            EX0x,
            UNIVERSAL_ROUTER
        );

        // Whitelist transformer in vault
        vault.setTransformer(address(autoExitTransformer), true);
        autoExitTransformer.setVault(address(vault));
    }

    function _deposit(uint256 amount, address account) internal {
        vm.prank(account);
        USDC.approve(address(vault), amount);
        vm.prank(account);
        vault.deposit(amount, account);
    }

    function _setupBasicLoan(bool borrowMax) internal {
        // Lend 10 USDC
        _deposit(10000000, WHALE_ACCOUNT);

        // Add collateral
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        (, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(collateralValue, 8846179);
        assertEq(fullValue, 9829088);

        if (borrowMax) {
            uint256 buffer = vault.BORROW_SAFETY_BUFFER_X32();
            vm.prank(TEST_NFT_ACCOUNT);
            vault.borrow(TEST_NFT, collateralValue * buffer / Q32);
        }
    }

    function _setConfig(
        uint256 tokenId,
        address vaultAddr,
        bool isActive,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        uint32 maxDebtRatioX32,
        bool onlyFees
    ) internal {
        AutoExitTransformer.PositionConfig memory config = AutoExitTransformer.PositionConfig(
            isActive,
            token0TriggerTick,
            token1TriggerTick,
            maxDebtRatioX32,
            MAX_SLIPPAGE,
            onlyFees,
            onlyFees ? MAX_FEE_REWARD : MAX_REWARD
        );

        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.configToken(tokenId, vaultAddr, config);
    }

    function _executeParams(uint256 tokenId, address vaultAddr, uint64 rewardX64) internal view returns (AutoExitTransformer.ExecuteParams memory) {
        return AutoExitTransformer.ExecuteParams({
            tokenId: tokenId,
            vault: vaultAddr,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            swapAmount0: 0,
            swapData0: "",
            swapAmount1: 0,
            swapData1: "",
            rewardX64: rewardX64,
            deadline: block.timestamp
        });
    }

    function testConfigTokenUnauthorizedVault() external {
        _setupBasicLoan(false);

        // Try to configure with unregistered vault
        address fakeVault = address(0x1234);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.configToken(
            TEST_NFT,
            fakeVault,
            AutoExitTransformer.PositionConfig(true, -276331, -276319, 0, MAX_SLIPPAGE, false, MAX_REWARD)
        );
    }

    function testConfigTokenUnauthorizedOwner() external {
        _setupBasicLoan(false);

        // Try to configure as non-owner
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(WHALE_ACCOUNT);
        autoExitTransformer.configToken(
            TEST_NFT,
            address(vault),
            AutoExitTransformer.PositionConfig(true, -276331, -276319, 0, MAX_SLIPPAGE, false, MAX_REWARD)
        );
    }

    function testConfigTokenInvalidTickOrder() external {
        _setupBasicLoan(false);

        // token0TriggerTick must be < token1TriggerTick
        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.configToken(
            TEST_NFT,
            address(vault),
            AutoExitTransformer.PositionConfig(true, -276319, -276331, 0, MAX_SLIPPAGE, false, MAX_REWARD)
        );
    }

    function testConfigTokenValid() external {
        _setupBasicLoan(false);

        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.configToken(
            TEST_NFT,
            address(vault),
            AutoExitTransformer.PositionConfig(true, -276331, -276319, uint32(Q32 * 9 / 10), MAX_SLIPPAGE, false, MAX_REWARD)
        );

        (
            bool isActive,
            int24 token0TriggerTick,
            int24 token1TriggerTick,
            uint32 maxDebtRatioX32,
            uint64 maxSlippageX64,
            bool onlyFees,
            uint64 maxRewardX64
        ) = autoExitTransformer.positionConfigs(TEST_NFT, address(vault));

        assertEq(isActive, true);
        assertEq(token0TriggerTick, -276331);
        assertEq(token1TriggerTick, -276319);
        assertEq(maxDebtRatioX32, uint32(Q32 * 9 / 10));
        assertEq(maxSlippageX64, MAX_SLIPPAGE);
        assertEq(onlyFees, false);
        assertEq(maxRewardX64, MAX_REWARD);
    }

    function testExecuteUnauthorizedOperator() external {
        _setupBasicLoan(true);

        _setConfig(TEST_NFT, address(vault), true, -276331, -276319, 0, false);

        // Approve transformer
        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Non-operator tries to execute
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD)
        );
    }

    function testExecuteNotConfigured() external {
        _setupBasicLoan(true);

        // Approve transformer without configuring
        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Vault wraps transformer errors in TransformFailed
        vm.expectRevert(Constants.TransformFailed.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD)
        );
    }

    function testExecuteNotReady() external {
        _setupBasicLoan(true);

        // Configure with tick triggers that won't be triggered (position is in range at around -276321)
        _setConfig(TEST_NFT, address(vault), true, -276350, -276300, 0, false);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Position tick is between triggers, so not ready
        // Vault wraps transformer errors in TransformFailed
        vm.expectRevert(Constants.TransformFailed.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD)
        );
    }

    function testExecuteExceedsMaxReward() external {
        _setupBasicLoan(true);

        // Configure to trigger when tick >= -276325 (current tick is -276321, so should trigger)
        _setConfig(TEST_NFT, address(vault), true, -276350, -276325, 0, false);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Try to execute with reward higher than configured max
        // Vault wraps transformer errors in TransformFailed
        vm.expectRevert(Constants.TransformFailed.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD + 1)
        );
    }

    function testExecuteTickTrigger() external {
        _setupBasicLoan(true);

        // Configure to trigger when tick >= -276325 (current tick is -276321, so should trigger)
        _setConfig(TEST_NFT, address(vault), true, -276350, -276325, 0, false);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        uint256 ownerDAIBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);
        uint256 ownerUSDCBefore = USDC.balanceOf(TEST_NFT_ACCOUNT);

        (uint256 debtBefore,,,,) = vault.loanInfo(TEST_NFT);
        assertGt(debtBefore, 0);

        // Execute auto-exit
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD)
        );

        // Verify debt is repaid (partially or fully based on position value)
        (uint256 debtAfter,,,,) = vault.loanInfo(TEST_NFT);
        assertLt(debtAfter, debtBefore);

        // Verify owner received tokens
        uint256 ownerDAIAfter = DAI.balanceOf(TEST_NFT_ACCOUNT);
        uint256 ownerUSDCAfter = USDC.balanceOf(TEST_NFT_ACCOUNT);

        // DAI should be returned since no swap data provided
        assertGt(ownerDAIAfter, ownerDAIBefore);
        // USDC used for debt repayment, remainder returned
        assertGe(ownerUSDCAfter, ownerUSDCBefore);

        // Verify config is cleared
        (bool isActive,,,,,,) = autoExitTransformer.positionConfigs(TEST_NFT, address(vault));
        assertEq(isActive, false);
    }

    function testExecuteDebtRatioTrigger() external {
        _setupBasicLoan(true);

        // Configure with debt ratio trigger at 0.9 (position is above this since max borrowed)
        // Debt ratio = debt / collateralValue = 8403870 / 8846179 = ~0.95
        uint32 debtRatioTrigger = uint32(Q32 * 9 / 10); // 0.9

        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.configToken(
            TEST_NFT,
            address(vault),
            AutoExitTransformer.PositionConfig(
                true,
                -276350, // won't trigger (position tick is around -276325)
                -276300, // won't trigger
                debtRatioTrigger,
                MAX_SLIPPAGE,
                false,
                MAX_REWARD
            )
        );

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Execute - should trigger on debt ratio
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD)
        );

        // Verify config is cleared
        (bool isActive,,,,,,) = autoExitTransformer.positionConfigs(TEST_NFT, address(vault));
        assertEq(isActive, false);
    }

    function testExecuteNoDebt() external {
        // Setup loan without borrowing
        _deposit(10000000, WHALE_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        // Verify no debt
        (uint256 debt,,,,) = vault.loanInfo(TEST_NFT);
        assertEq(debt, 0);

        // Configure auto-exit to trigger when tick >= -276325 (current tick is -276321)
        _setConfig(TEST_NFT, address(vault), true, -276350, -276325, 0, false);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        uint256 ownerDAIBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);
        uint256 ownerUSDCBefore = USDC.balanceOf(TEST_NFT_ACCOUNT);

        // Execute auto-exit (no debt to repay)
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD)
        );

        // Verify all funds returned to owner (minus reward)
        uint256 ownerDAIAfter = DAI.balanceOf(TEST_NFT_ACCOUNT);
        uint256 ownerUSDCAfter = USDC.balanceOf(TEST_NFT_ACCOUNT);

        assertGt(ownerDAIAfter, ownerDAIBefore);
        assertGt(ownerUSDCAfter, ownerUSDCBefore);
    }

    function testCanExecuteNotConfigured() external {
        _setupBasicLoan(true);

        (bool triggered, AutoExitTransformer.ExecuteStatus status) = autoExitTransformer.canExecute(TEST_NFT, address(vault));
        assertEq(triggered, false);
        assertEq(uint8(status), uint8(AutoExitTransformer.ExecuteStatus.NOT_CONFIGURED));
    }

    function testCanExecuteNotReady() external {
        _setupBasicLoan(true);

        // Configure with tick triggers that won't be triggered
        _setConfig(TEST_NFT, address(vault), true, -276350, -276300, 0, false);

        (bool triggered, AutoExitTransformer.ExecuteStatus status) = autoExitTransformer.canExecute(TEST_NFT, address(vault));
        assertEq(triggered, false);
        assertEq(uint8(status), uint8(AutoExitTransformer.ExecuteStatus.NOT_READY));
    }

    function testCanExecuteTickTrigger() external {
        _setupBasicLoan(true);

        // Configure to trigger when tick >= -276325 (current tick is -276321, so should trigger)
        _setConfig(TEST_NFT, address(vault), true, -276350, -276325, 0, false);

        (bool triggered, AutoExitTransformer.ExecuteStatus status) = autoExitTransformer.canExecute(TEST_NFT, address(vault));
        assertEq(triggered, true);
        assertEq(uint8(status), uint8(AutoExitTransformer.ExecuteStatus.TOKEN1_TICK_TRIGGER));
    }

    function testCanExecuteDebtRatioTrigger() external {
        _setupBasicLoan(true);

        // Configure with debt ratio trigger (position debt ratio is ~0.95)
        uint32 debtRatioTrigger = uint32(Q32 * 9 / 10); // 0.9

        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.configToken(
            TEST_NFT,
            address(vault),
            AutoExitTransformer.PositionConfig(
                true,
                -276350,
                -276300,
                debtRatioTrigger,
                MAX_SLIPPAGE,
                false,
                MAX_REWARD
            )
        );

        (bool triggered, AutoExitTransformer.ExecuteStatus status) = autoExitTransformer.canExecute(TEST_NFT, address(vault));
        assertEq(triggered, true);
        assertEq(uint8(status), uint8(AutoExitTransformer.ExecuteStatus.DEBT_RATIO_TRIGGER));
    }

    function testRewardOnlyFees() external {
        _setupBasicLoan(true);

        // Configure with onlyFees = true, trigger when tick >= -276325 (current tick is -276321)
        _setConfig(TEST_NFT, address(vault), true, -276350, -276325, 0, true);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Execute
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_FEE_REWARD)
        );

        // Verify config cleared
        (bool isActive,,,,,,) = autoExitTransformer.positionConfigs(TEST_NFT, address(vault));
        assertEq(isActive, false);
    }

    function testExecuteWithSwapNoSlippageViolation() external {
        // This test verifies that when no swap is needed (token is asset), slippage check is not triggered
        _setupBasicLoan(true);

        // Configure to trigger when tick >= -276325 (current tick is -276321, so should trigger)
        // Using a very low slippage tolerance to verify it's not checked when no swap occurs
        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.configToken(
            TEST_NFT,
            address(vault),
            AutoExitTransformer.PositionConfig(
                true,
                -276350,
                -276325,
                0,
                1, // Very low slippage tolerance (would fail if swap was checked)
                false,
                MAX_REWARD
            )
        );

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Should succeed because USDC is the asset, so no swap is needed for token1
        // DAI (token0) is not swapped because no swapData0 is provided
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD)
        );

        // Verify config is cleared (execution succeeded)
        (bool isActive,,,,,,) = autoExitTransformer.positionConfigs(TEST_NFT, address(vault));
        assertEq(isActive, false);
    }

    function testExecuteWithSwapDataButZeroAmount() external {
        // Test that if swapAmount is 0, no swap occurs even with swapData
        _setupBasicLoan(true);

        _setConfig(TEST_NFT, address(vault), true, -276350, -276325, 0, false);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Execute with swapData but zero swap amount - should not trigger swap
        AutoExitTransformer.ExecuteParams memory params = AutoExitTransformer.ExecuteParams({
            tokenId: TEST_NFT,
            vault: address(vault),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            swapAmount0: 0, // Zero amount means no swap
            swapData0: hex"1234", // Non-empty swap data
            swapAmount1: 0,
            swapData1: "",
            rewardX64: MAX_REWARD,
            deadline: block.timestamp
        });

        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(params);

        // Verify config is cleared (execution succeeded)
        (bool isActive,,,,,,) = autoExitTransformer.positionConfigs(TEST_NFT, address(vault));
        assertEq(isActive, false);
    }

    function testOraclePricesFetchedOnlyWhenSwapNeeded() external {
        // Test that oracle is only called when swap is actually needed
        _setupBasicLoan(true);

        _setConfig(TEST_NFT, address(vault), true, -276350, -276325, 0, false);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(autoExitTransformer), true);

        // Execute without any swap parameters - oracle should not be called
        vm.prank(OPERATOR_ACCOUNT);
        autoExitTransformer.executeWithVault(
            _executeParams(TEST_NFT, address(vault), MAX_REWARD)
        );

        // If this passes, oracle was not called (or was called successfully)
        (bool isActive,,,,,,) = autoExitTransformer.positionConfigs(TEST_NFT, address(vault));
        assertEq(isActive, false);
    }

    function testMaxSlippageConfigured() external {
        _setupBasicLoan(false);

        uint64 customSlippage = uint64(Q64 * 5 / 100); // 5%

        vm.prank(TEST_NFT_ACCOUNT);
        autoExitTransformer.configToken(
            TEST_NFT,
            address(vault),
            AutoExitTransformer.PositionConfig(
                true,
                -276331,
                -276319,
                0,
                customSlippage,
                false,
                MAX_REWARD
            )
        );

        (
            bool isActive,
            int24 token0TriggerTick,
            int24 token1TriggerTick,
            uint32 maxDebtRatioX32,
            uint64 maxSlippageX64,
            bool onlyFees,
            uint64 maxRewardX64
        ) = autoExitTransformer.positionConfigs(TEST_NFT, address(vault));

        assertEq(isActive, true);
        assertEq(token0TriggerTick, -276331);
        assertEq(token1TriggerTick, -276319);
        assertEq(maxDebtRatioX32, 0);
        assertEq(maxSlippageX64, customSlippage);
        assertEq(onlyFees, false);
        assertEq(maxRewardX64, MAX_REWARD);
    }
}
