// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";

import "./AerodromeTestBase.sol";
import "./mocks/MockChainlinkFeed.sol";
import "./mocks/MockB20Token.sol";

import "../../../src/InterestRateModel.sol";

/// @notice Test base for the Coinbase B20 equity-collateral vault design
///         using the parameters in deployments/base-coinbase-equity.json.
///         Reuses the Aerodrome mocks, then replaces `oracle` and `vault` with the
///         B20 configuration: USDC reference on its raw feed (forced CHAINLINK), equities in
///         CHAINLINK_TWAP_VERIFY on raw token-basis feeds, pilot factors and caps.
abstract contract B20TestBase is AerodromeTestBase {
    // manifest values
    uint32 constant CF_85 = 3_650_722_201;
    uint32 constant CF_55 = 2_362_232_012;
    uint32 constant CF_50 = 2_147_483_648;
    uint32 constant CAP_NVDA_PILOT = 150_323_855; // 3.5% of lent
    uint32 constant CAP_MSFT_PILOT = 107_374_182; // 2.5% of lent
    uint32 constant EQUITY_MAX_FEED_AGE = 7_200; // 2h operational window
    uint32 constant EQUITY_LIQUIDATION_MAX_FEED_AGE = 108_000; // 30h liquidation-only window
    uint32 constant USDC_MAX_FEED_AGE = 86_400;
    uint16 constant EQUITY_MAX_DIFFERENCE = 300; // 3%
    uint16 constant MAX_POOL_PRICE_DIFFERENCE = 300;
    uint32 constant TWAP_SECONDS = 60;
    int24 constant EQUITY_TICK_SPACING = 10;
    uint256 constant MIN_LOAN_SIZE = 1_000e6;

    // price of one raw token unit in raw USDC units, as a tick: 1.0001^tick
    // NVDAc ~ $218/share -> 2.18 USDC-units per NVDAc-unit (8 vs 6 decimals); MSFTc ~ $505
    int24 constant NVDA_START_TICK = 7_807;
    int24 constant MSFT_START_TICK = 16_195;

    // 8 feed decimals * 10^(8 token decimals - 6 reference decimals)
    uint256 constant FEED_UNITS_PER_REF_PRICE = 1e10;

    MockB20Token public nvdac;
    MockB20Token public msftc;
    MockChainlinkFeed public usdcRefFeed;
    MockChainlinkFeed public nvdaFeed;
    MockChainlinkFeed public msftFeed;
    MockPool public nvdaPool;
    MockPool public msftPool;
    MockPool public crossPool;

    int24 public nvdaTick = NVDA_START_TICK;
    int24 public msftTick = MSFT_START_TICK;

    address public lender = address(0x11);
    address public borrower = address(0x12);
    address public liquidator = address(0x13);

    uint256 internal nextTokenId = 1_000_000;

    function lendAmount() internal view virtual returns (uint256) {
        return 200_000e6;
    }

    function setUp() public virtual override {
        vm.warp(1_760_000_000); // realistic timestamps for feed-age arithmetic
        super.setUp();

        nvdac = new MockB20Token("Coinbase Wrapped NVDA", "NVDAc");
        msftc = new MockB20Token("Coinbase Wrapped MSFT", "MSFTc");

        usdcRefFeed = new MockChainlinkFeed(1e8, 8);
        nvdaFeed = new MockChainlinkFeed(1, 8);
        msftFeed = new MockChainlinkFeed(1, 8);
        nvdaPool = _deployPool(address(nvdac), address(usdc));
        msftPool = _deployPool(address(msftc), address(usdc));
        crossPool = _deployPool(address(nvdac), address(msftc));

        _moveNvda(NVDA_START_TICK);
        _moveMsft(MSFT_START_TICK);

        oracle = new V3Oracle(npm, address(usdc), address(0));
        oracle.setMaxPoolPriceDifference(MAX_POOL_PRICE_DIFFERENCE);
        oracle.setTokenConfig(
            address(usdc),
            AggregatorV3Interface(address(usdcRefFeed)),
            USDC_MAX_FEED_AGE,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );
        oracle.setTokenConfig(
            address(nvdac),
            AggregatorV3Interface(address(nvdaFeed)),
            EQUITY_MAX_FEED_AGE,
            EQUITY_LIQUIDATION_MAX_FEED_AGE,
            IUniswapV3Pool(address(nvdaPool)),
            TWAP_SECONDS,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            EQUITY_MAX_DIFFERENCE
        );
        oracle.setTokenConfig(
            address(msftc),
            AggregatorV3Interface(address(msftFeed)),
            EQUITY_MAX_FEED_AGE,
            EQUITY_LIQUIDATION_MAX_FEED_AGE,
            IUniswapV3Pool(address(msftPool)),
            TWAP_SECONDS,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            EQUITY_MAX_DIFFERENCE
        );

        // live Aerodrome IRM parameters; the mock IRM's 1%/s rate is unusable across a 30h blackout
        InterestRateModel b20Irm = new InterestRateModel(0, Q64 * 13 / 100, Q64 * 300 / 100, Q64 * 90 / 100);

        vault = new V3Vault("Revert Lend Coinbase Equities USDC", "rlCbEqUSDC", address(usdc), npm, b20Irm, oracle);
        vault.setTokenConfig(address(usdc), CF_85, type(uint32).max);
        vault.setTokenConfig(address(nvdac), CF_50, CAP_NVDA_PILOT);
        vault.setTokenConfig(address(msftc), CF_55, CAP_MSFT_PILOT);
        vault.setLimits(MIN_LOAN_SIZE, 2_000_000e6, 1_000_000e6, lendAmount(), 100_000e6);

        // lenders must deposit in setUp: same-tx deposits are excluded from the cap base (tload guard)
        usdc.mint(lender, lendAmount());
        vm.startPrank(lender);
        usdc.approve(address(vault), lendAmount());
        vault.deposit(lendAmount(), lender);
        vm.stopPrank();

        vm.label(address(nvdac), "NVDAc");
        vm.label(address(msftc), "MSFTc");
        vm.label(address(nvdaPool), "NVDAc/USDC");
        vm.label(address(msftPool), "MSFTc/USDC");
        vm.label(address(crossPool), "NVDAc/MSFTc");
    }

    // ---- pool / feed helpers -------------------------------------------------------------

    function _deployPool(address tokenA, address tokenB) internal returns (MockPool pool) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = new MockPool(token0, token1, uint24(uint256(int256(EQUITY_TICK_SPACING))), EQUITY_TICK_SPACING);
        factory.setPool(token0, token1, EQUITY_TICK_SPACING, address(pool));
    }

    /// @dev sets spot and TWAP of `pool` so that `token` is worth 1.0001^refTick reference units
    function _setRefTick(MockPool pool, address token, int24 refTick) internal {
        int24 poolTick = pool.token0() == token ? refTick : -refTick;
        pool.setTick(poolTick);
        pool.setObservedTick(poolTick);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(poolTick));
    }

    /// @dev price of one raw token unit in raw reference units, X96
    function _refPriceX96(int24 refTick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(refTick);
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
    }

    /// @dev Chainlink's total-return token answer (8 decimals), with the multiplier already included.
    function _fairTokenAnswer(int24 refTick) internal pure returns (int256) {
        return int256(FullMath.mulDiv(_refPriceX96(refTick), FEED_UNITS_PER_REF_PRICE, Q96));
    }

    function _syncCrossPool() internal {
        int24 crossTick = crossPool.token0() == address(nvdac) ? nvdaTick - msftTick : msftTick - nvdaTick;
        crossPool.setTick(crossTick);
        crossPool.setObservedTick(crossTick);
        crossPool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(crossTick));
    }

    /// @dev market move: pool and total-return token feed reprice together
    function _moveNvda(int24 refTick) internal {
        nvdaTick = refTick;
        _setRefTick(nvdaPool, address(nvdac), refTick);
        nvdaFeed.setAnswer(_fairTokenAnswer(refTick));
        _syncCrossPool();
    }

    function _moveMsft(int24 refTick) internal {
        msftTick = refTick;
        _setRefTick(msftPool, address(msftc), refTick);
        msftFeed.setAnswer(_fairTokenAnswer(refTick));
        _syncCrossPool();
    }

    function _refreshFeeds() internal {
        usdcRefFeed.setUpdatedAt(block.timestamp);
        nvdaFeed.setUpdatedAt(block.timestamp);
        msftFeed.setUpdatedAt(block.timestamp);
    }

    // ---- position / loan helpers ---------------------------------------------------------

    /// @dev position whose value comes from tokensOwed (liquidity 1 is negligible); exact and pool-independent
    function _mintPosition(address owner, address tokenA, address tokenB, uint128 amountA, uint128 amountB)
        internal
        returns (uint256 tokenId)
    {
        tokenId = nextTokenId++;
        npm.mint(owner, tokenId);
        npm.setPosition(tokenId, tokenA, tokenB, EQUITY_TICK_SPACING, -887_220, 887_220, 1);
        if (tokenA < tokenB) {
            npm.setTokensOwed(tokenId, amountA, amountB);
        } else {
            npm.setTokensOwed(tokenId, amountB, amountA);
        }
    }

    function _mintNvdaPosition(address owner, uint128 nvdaAmount, uint128 usdcAmount) internal returns (uint256) {
        return _mintPosition(owner, address(nvdac), address(usdc), nvdaAmount, usdcAmount);
    }

    function _mintMsftPosition(address owner, uint128 msftAmount, uint128 usdcAmount) internal returns (uint256) {
        return _mintPosition(owner, address(msftc), address(usdc), msftAmount, usdcAmount);
    }

    function _mintCrossPosition(address owner, uint128 nvdaAmount, uint128 msftAmount) internal returns (uint256) {
        return _mintPosition(owner, address(nvdac), address(msftc), nvdaAmount, msftAmount);
    }

    function _deposit(address owner, uint256 tokenId) internal {
        vm.startPrank(owner);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, owner);
        vm.stopPrank();
    }

    function _borrow(address owner, uint256 tokenId, uint256 amount) internal {
        vm.prank(owner);
        vault.borrow(tokenId, amount);
    }

    function _expectBorrowRevert(address owner, uint256 tokenId, uint256 amount, bytes4 selector) internal {
        vm.prank(owner);
        vm.expectRevert(selector);
        vault.borrow(tokenId, amount);
    }

    function _liquidate(address who, uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        usdc.mint(who, debt);
        vm.startPrank(who);
        usdc.approve(address(vault), debt);
        (amount0, amount1) = vault.liquidate(
            IVault.LiquidateParams({
                tokenId: tokenId, amount0Min: 0, amount1Min: 0, recipient: who, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function _value(uint256 tokenId) internal view returns (uint256 value) {
        (value,,,) = oracle.getValue(tokenId, address(usdc), false);
    }

    function _expectValueRevert(uint256 tokenId, bytes4 selector) internal {
        vm.expectRevert(selector);
        oracle.getValue(tokenId, address(usdc), false);
    }
}
