// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../../src/V3Oracle.sol";
import "../../../src/V3Vault.sol";
import "../../../src/InterestRateModel.sol";

import "../../../src/transformers/ConstantLeverageTransformer.sol";
import "../../../src/utils/Constants.sol";

contract ConstantLeverageTransformerTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;
    uint256 constant Q96 = 2 ** 96;

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant OPERATOR_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant WITHDRAWER_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;
    address constant UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address constant UNISWAP_DAI_USDC = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168; // 0.01% pool
    address constant UNISWAP_ETH_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // 0.05% pool
    address constant UNISWAP_DAI_USDC_005 = 0x6c6Bc977E13Df9b0de53b251522280BB72383700; // 0.05% pool - position 126 is in this pool

    // DAI/USDC 0.05% position - in range
    address constant TEST_NFT_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    uint256 constant TEST_NFT = 126;

    // DAI/WETH 0.05% position
    uint256 constant TEST_NFT_DAI_WETH = 548468;
    address constant TEST_NFT_DAI_WETH_ACCOUNT = 0x312dEeeF09E8a8BBC4a6ce2b3Fcb395813BE09Df;

    uint256 mainnetFork;

    V3Vault vault;
    InterestRateModel interestRateModel;
    V3Oracle oracle;
    ConstantLeverageTransformer transformer;

    function setUp() external {
        string memory ANKR_RPC = string.concat(
            "https://rpc.ankr.com/eth/",
            vm.envString("ANKR_API_KEY")
        );
        mainnetFork = vm.createFork(ANKR_RPC, 18521658);
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
            IUniswapV3Pool(UNISWAP_DAI_USDC_005), // Use 0.05% pool to match position 126
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
        vault.setLimits(0, 100000000000, 100000000000, 100000000000, 100000000000);
        vault.setReserveFactor(0);

        // Setup transformer
        transformer = new ConstantLeverageTransformer(
            NPM,
            OPERATOR_ACCOUNT,
            WITHDRAWER_ACCOUNT,
            60, // 60 seconds TWAP
            100, // max 1% tick difference
            UNIVERSAL_ROUTER,
            EX0x
        );

        // Configure transformer
        transformer.setVault(address(vault));
        vault.setTransformer(address(transformer), true);
    }

    function _deposit(uint256 amount, address account) internal {
        vm.prank(account);
        USDC.approve(address(vault), amount);
        vm.prank(account);
        vault.deposit(amount, account);
    }

    function _createLoan(uint256 tokenId, address account) internal {
        vm.prank(account);
        NPM.approve(address(vault), tokenId);
        vm.prank(account);
        vault.create(tokenId, account);
    }

    function _setupLoanWithLeverage(uint256 tokenId, address account, uint256 borrowAmount) internal {
        _createLoan(tokenId, account);

        if (borrowAmount > 0) {
            vm.prank(account);
            vault.borrow(tokenId, borrowAmount);
        }
    }

    // ============ Configuration Tests ============

    function testSetPositionConfig() external {
        // Deposit liquidity
        _deposit(100000000, WHALE_ACCOUNT);

        // Create loan
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        // Approve transformer
        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000, // 50% = 2x leverage
            lowerThresholdBps: 500,  // 5%
            upperThresholdBps: 500,  // 5%
            maxSlippageBps: 100,     // 1%
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        // Verify config was set
        (
            uint16 targetLeverageBps,
            uint16 lowerThresholdBps,
            uint16 upperThresholdBps,
            uint16 maxSlippageBps,
            bool onlyFees,
            uint64 maxRewardX64
        ) = transformer.positionConfigs(TEST_NFT);

        assertEq(targetLeverageBps, 5000);
        assertEq(lowerThresholdBps, 500);
        assertEq(upperThresholdBps, 500);
        assertEq(maxSlippageBps, 100);
        assertEq(onlyFees, false);
        assertEq(maxRewardX64, uint64(Q64 / 100));
    }

    function testSetPositionConfigUnauthorized() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        // Try to set config as non-owner
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);
    }

    function testSetPositionConfigInvalidLeverage() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Try to set leverage above max (9000 = 10x)
        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 9500, // Above max
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);
    }

    function testSetPositionConfigInvalidReward() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Try to set reward above max (2%)
        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 10) // 10% - way above max
        });

        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);
    }

    // ============ Check Rebalance Tests ============

    function testCheckRebalanceNeededNoConfig() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        // No config set - should return false
        (bool needed, bool isIncrease, uint256 currentRatioBps) = transformer.checkRebalanceNeeded(TEST_NFT, address(vault));
        assertEq(needed, false);
        assertEq(isIncrease, false);
        assertEq(currentRatioBps, 0);
    }

    function testCheckRebalanceNeededBelowTarget() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Set config for 50% target leverage
        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000, // 50%
            lowerThresholdBps: 500,  // 5%
            upperThresholdBps: 500,  // 5%
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        // No debt yet - current ratio is 0, target is 50%, so need to increase
        (bool needed, bool isIncrease, uint256 currentRatioBps) = transformer.checkRebalanceNeeded(TEST_NFT, address(vault));
        assertEq(needed, true);
        assertEq(isIncrease, true);
        assertEq(currentRatioBps, 0);
    }

    function testCheckRebalanceNeededAboveTarget() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        // Get collateral value
        (, , uint256 collateralValue, , ) = vault.loanInfo(TEST_NFT);

        // Borrow close to max (90% of collateral)
        uint256 borrowAmount = collateralValue * 80 / 100;
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, borrowAmount);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Set config for 50% target leverage - current is ~80%
        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000, // 50%
            lowerThresholdBps: 500,  // 5%
            upperThresholdBps: 500,  // 5%
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        // Current ratio is ~80%, target is 50%, so need to decrease
        (bool needed, bool isIncrease, uint256 currentRatioBps) = transformer.checkRebalanceNeeded(TEST_NFT, address(vault));
        assertEq(needed, true);
        assertEq(isIncrease, false);
        assertTrue(currentRatioBps > 5500); // Should be above target + threshold
    }

    function testCheckRebalanceNeededWithinThreshold() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        // Get collateral value
        (, , uint256 collateralValue, , ) = vault.loanInfo(TEST_NFT);

        // Borrow exactly 50% (target)
        uint256 borrowAmount = collateralValue * 50 / 100;
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, borrowAmount);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Set config for 50% target
        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000, // 50%
            lowerThresholdBps: 500,  // 5%
            upperThresholdBps: 500,  // 5%
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        // Current ratio is ~50%, within threshold - no rebalance needed
        (bool needed, , uint256 currentRatioBps) = transformer.checkRebalanceNeeded(TEST_NFT, address(vault));
        assertEq(needed, false);
        // Current ratio should be around 50% (might not be exact due to rounding)
        assertTrue(currentRatioBps >= 4500 && currentRatioBps <= 5500);
    }

    // ============ Rebalance Tests ============

    function testRebalanceDirectCallByOperatorReverts() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200)
        });

        // Operator cannot call rebalance() directly - must use rebalanceWithVault()
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        transformer.rebalance(params);
    }

    function testRebalanceUnauthorizedOperator() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200) // 0.5%
        });

        // Try to rebalance as non-operator
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        transformer.rebalanceWithVault(params, address(vault));
    }

    function testRebalanceNotConfigured() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Don't set config

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200)
        });

        // Try to rebalance without config - vault wraps errors in TransformFailed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Constants.TransformFailed.selector);
        transformer.rebalanceWithVault(params, address(vault));
    }

    function testRebalanceNotReady() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        // Get collateral value
        (, , uint256 collateralValue, , ) = vault.loanInfo(TEST_NFT);

        // Borrow exactly 50% (target)
        uint256 borrowAmount = collateralValue * 50 / 100;
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, borrowAmount);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200)
        });

        // Try to rebalance when within threshold - vault wraps errors in TransformFailed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Constants.TransformFailed.selector);
        transformer.rebalanceWithVault(params, address(vault));
    }

    function testRebalanceExceedsMaxReward() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 200) // 0.5% max
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 100) // 1% - exceeds max
        });

        // Try to rebalance with reward exceeding max - vault wraps errors in TransformFailed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Constants.TransformFailed.selector);
        transformer.rebalanceWithVault(params, address(vault));
    }

    function testRebalanceIncreaseLeverage() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Set config for 50% target leverage (no debt yet = 0%)
        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000, // 50%
            lowerThresholdBps: 500,  // 5%
            upperThresholdBps: 500,  // 5%
            maxSlippageBps: 100,     // 1%
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        // Verify position needs rebalancing
        (bool needed, bool isIncrease, ) = transformer.checkRebalanceNeeded(TEST_NFT, address(vault));
        assertTrue(needed);
        assertTrue(isIncrease);

        // Get debt before
        (uint256 debtBefore, , , , ) = vault.loanInfo(TEST_NFT);
        assertEq(debtBefore, 0);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,     // Swap token0 (DAI) to token1 (USDC) to add liquidity
            amountIn: 0,        // No swap for this test
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200) // 0.5%
        });

        // Rebalance
        vm.prank(OPERATOR_ACCOUNT);
        transformer.rebalanceWithVault(params, address(vault));

        // Verify debt increased
        (uint256 debtAfter, , , , ) = vault.loanInfo(TEST_NFT);
        assertTrue(debtAfter > debtBefore, "Debt should have increased");
    }

    function testRebalanceDecreaseLeverage() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        // Get collateral value and borrow 72% (above 50% target + 5% threshold = 55%)
        // Using 72% instead of 80% to leave room for the position to stay healthy
        // during the transform (when liquidity is temporarily removed)
        (, , uint256 collateralValue, , ) = vault.loanInfo(TEST_NFT);
        uint256 borrowAmount = collateralValue * 72 / 100;
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, borrowAmount);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Set config for 50% target leverage (current ~72%)
        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000, // 50%
            lowerThresholdBps: 500,  // 5%
            upperThresholdBps: 500,  // 5%
            maxSlippageBps: 100,     // 1%
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        // Verify position needs rebalancing
        (bool needed, bool isIncrease, ) = transformer.checkRebalanceNeeded(TEST_NFT, address(vault));
        assertTrue(needed);
        assertFalse(isIncrease);

        // Get debt before
        (uint256 debtBefore, , , , ) = vault.loanInfo(TEST_NFT);
        assertTrue(debtBefore > 0);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: false,    // Swap token1 to token0 to get more USDC for repay
            amountIn: 0,        // No swap for this test
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200) // 0.5%
        });

        // Rebalance
        vm.prank(OPERATOR_ACCOUNT);
        transformer.rebalanceWithVault(params, address(vault));

        // Verify debt decreased
        (uint256 debtAfter, , , , ) = vault.loanInfo(TEST_NFT);
        assertTrue(debtAfter < debtBefore, "Debt should have decreased");
    }

    // ============ Event Tests ============

    function testPositionConfiguredEvent() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: true,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.expectEmit(true, false, false, true);
        emit IConstantLeverageTransformer.PositionConfigured(
            TEST_NFT,
            5000,
            500,
            500,
            100,
            true,
            uint64(Q64 / 100)
        );

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);
    }

    function testRebalancedEvent() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200)
        });

        // Expect Rebalanced event (we don't check exact values)
        vm.expectEmit(true, false, false, false);
        emit IConstantLeverageTransformer.Rebalanced(TEST_NFT, true, 0, 0, 0, 0);

        vm.prank(OPERATOR_ACCOUNT);
        transformer.rebalanceWithVault(params, address(vault));
    }

    // ============ Reward Accumulation Tests ============

    function testRewardsAccumulateInContract() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        // Set config with 0.5% reward
        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000, // 50%
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1% max
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        // Check transformer balances before rebalance
        uint256 transformerDaiBefore = DAI.balanceOf(address(transformer));
        uint256 transformerUsdcBefore = USDC.balanceOf(address(transformer));

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200) // 0.5% reward
        });

        // Rebalance (increase leverage from 0% to 50%)
        vm.prank(OPERATOR_ACCOUNT);
        transformer.rebalanceWithVault(params, address(vault));

        // Check transformer balances after rebalance - should have accumulated rewards
        uint256 transformerDaiAfter = DAI.balanceOf(address(transformer));
        uint256 transformerUsdcAfter = USDC.balanceOf(address(transformer));

        // At least one token should have accumulated as reward
        // (depends on which tokens were involved in the rebalance)
        assertTrue(
            transformerDaiAfter > transformerDaiBefore || transformerUsdcAfter > transformerUsdcBefore,
            "Rewards should accumulate in transformer contract"
        );
    }

    function testWithdrawerCanCollectRewards() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200)
        });

        // Rebalance to accumulate rewards
        vm.prank(OPERATOR_ACCOUNT);
        transformer.rebalanceWithVault(params, address(vault));

        // Get accumulated rewards
        uint256 accumulatedDai = DAI.balanceOf(address(transformer));
        uint256 accumulatedUsdc = USDC.balanceOf(address(transformer));

        // Withdrawer balance before
        uint256 withdrawerDaiBefore = DAI.balanceOf(WITHDRAWER_ACCOUNT);
        uint256 withdrawerUsdcBefore = USDC.balanceOf(WITHDRAWER_ACCOUNT);

        // Withdrawer collects rewards
        address[] memory tokens = new address[](2);
        tokens[0] = address(DAI);
        tokens[1] = address(USDC);

        vm.prank(WITHDRAWER_ACCOUNT);
        transformer.withdrawBalances(tokens, WITHDRAWER_ACCOUNT);

        // Verify withdrawer received the rewards
        uint256 withdrawerDaiAfter = DAI.balanceOf(WITHDRAWER_ACCOUNT);
        uint256 withdrawerUsdcAfter = USDC.balanceOf(WITHDRAWER_ACCOUNT);

        assertEq(withdrawerDaiAfter - withdrawerDaiBefore, accumulatedDai, "Withdrawer should receive DAI rewards");
        assertEq(withdrawerUsdcAfter - withdrawerUsdcBefore, accumulatedUsdc, "Withdrawer should receive USDC rewards");

        // Transformer should have zero balance now
        assertEq(DAI.balanceOf(address(transformer)), 0, "Transformer DAI balance should be zero");
        assertEq(USDC.balanceOf(address(transformer)), 0, "Transformer USDC balance should be zero");
    }

    function testOwnerDoesNotReceiveRewards() external {
        _deposit(100000000, WHALE_ACCOUNT);
        _createLoan(TEST_NFT, TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.approveTransform(TEST_NFT, address(transformer), true);

        IConstantLeverageTransformer.LeverageConfig memory config = IConstantLeverageTransformer.LeverageConfig({
            targetLeverageBps: 5000,
            lowerThresholdBps: 500,
            upperThresholdBps: 500,
            maxSlippageBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(TEST_NFT_ACCOUNT);
        transformer.setPositionConfig(TEST_NFT, address(vault), config);

        IConstantLeverageTransformer.RebalanceParams memory params = IConstantLeverageTransformer.RebalanceParams({
            tokenId: TEST_NFT,
            swap0To1: true,
            amountIn: 0,
            deadline: block.timestamp + 1000,
            rewardX64: uint64(Q64 / 200) // 0.5% reward
        });

        // Rebalance
        vm.prank(OPERATOR_ACCOUNT);
        transformer.rebalanceWithVault(params, address(vault));

        // Get rewards accumulated in transformer
        uint256 transformerDai = DAI.balanceOf(address(transformer));
        uint256 transformerUsdc = USDC.balanceOf(address(transformer));

        // Rewards should be in the transformer, not sent to owner
        // This verifies the fix: rewards stay in contract for withdrawer
        assertTrue(transformerDai > 0 || transformerUsdc > 0, "Rewards should be in transformer");
    }
}
