// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";

import {V3Utils} from "../../src/transformers/V3Utils.sol";
import {AutoRangeAndCompound} from "../../src/transformers/AutoRangeAndCompound.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {MockERC20Token} from "./GaugeManager.t.sol";
import {
    ISlipstreamPositionManager,
    SlipstreamFactoryFixture,
    SlipstreamPoolFixture
} from "../mocks/SlipstreamFixture.sol";

/// @dev Forces ETH into a contract whose receive() would reject it: selfdestruct transfers the balance without a call.
contract ForceSend {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev Runs the unmodified, pinned upstream Slipstream NonfungiblePositionManager bytecode (fixtures/upstream-gauge)
/// under V3Utils and AutoRangeAndCompound. Its mint and increaseLiquidity end with refundETH(), which sends the
/// manager's whole ETH balance to the caller: with a WETH-only receive() one wei forced into the manager made every
/// V3Utils mint / increase and every AutoRangeAndCompound compound / range adjustment revert until someone called
/// refundETH() on the manager (Cantina scan #13, LEND-105 / LEND-111). Both contracts now accept the refund and the
/// owner (V3Utils) or withdrawer (Automator) sweeps it; every other sender is still rejected.
contract PositionManagerRefundETHTest is Test {
    uint256 constant Q128 = 1 << 128;
    int24 constant TICK_SPACING = 100;
    int24 constant TICK_LOWER = -1000;
    int24 constant TICK_UPPER = 1000;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96: price 1, tick 0
    address constant USER = address(0xA11CE);
    address constant OPERATOR = address(0x0B0B);
    address constant WITHDRAWER = address(0xD1D1);
    address constant STRANGER = address(0xBAD);
    address constant SWEEP_TO = address(0x5EE9);

    MockERC20Token weth;
    IERC20 token0;
    IERC20 token1;
    SlipstreamFactoryFixture factory;
    SlipstreamPoolFixture pool;
    ISlipstreamPositionManager npm;
    V3Utils v3utils;
    AutoRangeAndCompound autoRange;
    uint256 tokenId; // USER's position, minted through the upstream manager in setUp

    receive() external payable {}

    function setUp() public {
        weth = new MockERC20Token("Wrapped Ether", "WETH");
        MockERC20Token tokenA = new MockERC20Token("Token A", "A");
        MockERC20Token tokenB = new MockERC20Token("Token B", "B");
        (token0, token1) = address(tokenA) < address(tokenB)
            ? (IERC20(address(tokenA)), IERC20(address(tokenB)))
            : (IERC20(address(tokenB)), IERC20(address(tokenA)));

        factory = new SlipstreamFactoryFixture();
        pool = SlipstreamPoolFixture(factory.createPool(address(token0), address(token1), TICK_SPACING, SQRT_PRICE_1_1));
        npm = ISlipstreamPositionManager(
            deployCode(
                "fixtures/upstream-gauge/out/NonfungiblePositionManager.sol/NonfungiblePositionManager.json",
                abi.encode(
                    address(this), address(factory), address(weth), address(0), "Slipstream Position NFT", "SLIP-POS"
                )
            )
        );

        v3utils = new V3Utils(INonfungiblePositionManager(address(npm)), address(0), address(0));
        autoRange = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(npm)), OPERATOR, WITHDRAWER, 60, 100, address(0), address(0)
        );

        vm.deal(address(this), 1 ether);
        _fund(USER, 100 ether);
        tokenId = _mintThroughManager(USER, 10 ether);
    }

    // --- the mechanism, in the upstream bytecode ---

    function testUpstreamManagerRefundsForcedEthToTheMintCaller() public {
        _forceEthIntoManager(1);
        uint256 balanceBefore = address(this).balance;

        _mintThroughManager(USER, 1 ether);

        assertEq(address(npm).balance, 0, "the manager refunded its whole balance");
        assertEq(address(this).balance, balanceBefore + 1, "to the caller of mint");
    }

    // --- V3Utils ---

    function testSwapAndMintSucceedsWithEthForcedIntoTheManager() public {
        _forceEthIntoManager(1);

        vm.startPrank(USER);
        token0.approve(address(v3utils), 1 ether);
        token1.approve(address(v3utils), 1 ether);
        (uint256 newTokenId, uint128 liquidity,,) = v3utils.swapAndMint(_swapAndMintParams(1 ether));
        vm.stopPrank();

        assertGt(liquidity, 0);
        assertEq(npm.ownerOf(newTokenId), USER);
        assertEq(address(npm).balance, 0);
        assertEq(address(v3utils).balance, 1, "the refunded wei stays in V3Utils");
    }

    function testSwapAndIncreaseLiquiditySucceedsWithEthForcedIntoTheManager() public {
        _forceEthIntoManager(1);
        (,,,,,,, uint128 liquidityBefore,,,,) = npm.positions(tokenId);

        vm.startPrank(USER);
        token0.approve(address(v3utils), 1 ether);
        token1.approve(address(v3utils), 1 ether);
        (uint128 liquidity,,) = v3utils.swapAndIncreaseLiquidity(
            V3Utils.SwapAndIncreaseLiquidityParams(
                tokenId, 1 ether, 1 ether, USER, block.timestamp, IERC20(address(0)), 0, 0, "", 0, 0, "", 0, 0
            )
        );
        vm.stopPrank();

        (,,,,,,, uint128 liquidityAfter,,,,) = npm.positions(tokenId);
        assertGt(liquidity, 0);
        assertEq(liquidityAfter, liquidityBefore + liquidity);
        assertEq(address(npm).balance, 0);
        assertEq(address(v3utils).balance, 1, "the refunded wei stays in V3Utils");
    }

    function testV3UtilsOwnerSweepsRefundedEth() public {
        _forceEthIntoManager(1);
        vm.startPrank(USER);
        token0.approve(address(v3utils), 1 ether);
        token1.approve(address(v3utils), 1 ether);
        v3utils.swapAndMint(_swapAndMintParams(1 ether));
        vm.stopPrank();
        assertEq(address(v3utils).balance, 1);

        vm.prank(STRANGER);
        vm.expectRevert("Ownable: caller is not the owner");
        v3utils.withdrawETH(STRANGER);

        v3utils.withdrawETH(SWEEP_TO); // this contract deployed V3Utils and owns it
        assertEq(address(v3utils).balance, 0);
        assertEq(SWEEP_TO.balance, 1);

        v3utils.withdrawETH(SWEEP_TO); // nothing to sweep is not an error
        assertEq(SWEEP_TO.balance, 1);
    }

    // --- AutoRangeAndCompound ---

    function testAutoCompoundSucceedsWithEthForcedIntoTheManager() public {
        _configureAutoRange();
        _accrueFees(1 ether, 1 ether);
        _forceEthIntoManager(1);
        (,,,,,,, uint128 liquidityBefore,,,,) = npm.positions(tokenId);

        vm.prank(OPERATOR);
        autoRange.autoCompound(AutoRangeAndCompound.AutoCompoundParams(tokenId, false, 0, block.timestamp));

        (,,,,,,, uint128 liquidityAfter,,,,) = npm.positions(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "fees were compounded into the position");
        assertEq(address(npm).balance, 0);
        assertEq(address(autoRange).balance, 1, "the refunded wei stays in AutoRangeAndCompound");
    }

    function testExecuteRangeAdjustmentSucceedsWithEthForcedIntoTheManager() public {
        _configureAutoRange();
        _forceEthIntoManager(1);

        vm.prank(OPERATOR);
        autoRange.execute(AutoRangeAndCompound.ExecuteParams(tokenId, false, 0, "", 0, 0, 0, 0, block.timestamp, 0));

        uint256 newTokenId = tokenId + 1; // the next id of the upstream manager
        assertEq(npm.ownerOf(newTokenId), USER);
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = npm.positions(newTokenId);
        assertEq(tickLower, -200);
        assertEq(tickUpper, 200);
        assertGt(liquidity, 0);
        assertEq(address(npm).balance, 0);
        assertEq(address(autoRange).balance, 1, "the refunded wei stays in AutoRangeAndCompound");
    }

    function testAutoRangeWithdrawerSweepsRefundedEth() public {
        _configureAutoRange();
        _accrueFees(1 ether, 1 ether);
        _forceEthIntoManager(1);
        vm.prank(OPERATOR);
        autoRange.autoCompound(AutoRangeAndCompound.AutoCompoundParams(tokenId, false, 0, block.timestamp));
        assertEq(address(autoRange).balance, 1);

        vm.prank(STRANGER);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoRange.withdrawETH(STRANGER);

        vm.prank(WITHDRAWER);
        autoRange.withdrawETH(SWEEP_TO);
        assertEq(address(autoRange).balance, 0);
        assertEq(SWEEP_TO.balance, 1);
    }

    // --- receive() stays strict ---

    function testReceiveAcceptsOnlyWethAndThePositionManager() public {
        address[2] memory receivers = [address(v3utils), address(autoRange)];
        for (uint256 i; i < receivers.length; ++i) {
            address receiver = receivers[i];

            vm.deal(address(npm), 1);
            vm.prank(address(npm));
            (bool ok,) = receiver.call{value: 1}("");
            assertTrue(ok, "the position manager may send ETH");

            vm.deal(address(weth), 1);
            vm.prank(address(weth));
            (ok,) = receiver.call{value: 1}("");
            assertTrue(ok, "WETH may send ETH");

            vm.deal(STRANGER, 1);
            vm.prank(STRANGER);
            (bool accepted, bytes memory data) = receiver.call{value: 1}("");
            assertFalse(accepted, "anyone else is rejected");
            assertEq(data, abi.encodeWithSelector(Constants.NotWETH.selector));

            // the owner / deployer is no exception
            (accepted, data) = receiver.call{value: 1}("");
            assertFalse(accepted, "the owner is rejected as well");
            assertEq(data, abi.encodeWithSelector(Constants.NotWETH.selector));

            assertEq(receiver.balance, 2);
        }
    }

    // --- helpers ---

    function _forceEthIntoManager(uint256 amount) internal {
        new ForceSend{value: amount}(payable(address(npm)));
        assertEq(address(npm).balance, amount, "ETH sits in the position manager");
    }

    function _fund(address account, uint256 amount) internal {
        MockERC20Token(address(token0)).mint(account, amount);
        MockERC20Token(address(token1)).mint(account, amount);
    }

    /// @dev Mints a TICK_LOWER..TICK_UPPER position for `recipient` directly through the upstream manager.
    function _mintThroughManager(address recipient, uint256 amount) internal returns (uint256 id) {
        _fund(address(this), amount);
        token0.approve(address(npm), amount);
        token1.approve(address(npm), amount);
        (id,,,) = npm.mint(
            ISlipstreamPositionManager.MintParams(
                address(token0),
                address(token1),
                TICK_SPACING,
                TICK_LOWER,
                TICK_UPPER,
                amount,
                amount,
                0,
                0,
                recipient,
                block.timestamp,
                0
            )
        );
    }

    function _swapAndMintParams(uint256 amount) internal view returns (V3Utils.SwapAndMintParams memory) {
        return V3Utils.SwapAndMintParams(
            token0,
            token1,
            uint24(TICK_SPACING),
            TICK_LOWER,
            TICK_UPPER,
            amount,
            amount,
            USER,
            USER,
            block.timestamp,
            IERC20(address(0)),
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            ""
        );
    }

    /// @dev USER lets AutoRangeAndCompound manage the position: auto-compound on, in-range adjustments to
    /// baseTick - 200 .. baseTick + 200, no protocol reward.
    function _configureAutoRange() internal {
        vm.startPrank(USER);
        npm.approve(address(autoRange), tokenId);
        autoRange.configToken(
            tokenId,
            address(0),
            AutoRangeAndCompound.PositionConfig(-2000, -2000, -200, 200, 0, 0, false, true, 0, 0, 0, 0),
            AutoRangeAndCompound.CompoundMode.Advanced
        );
        vm.stopPrank();
    }

    /// @dev Credits `amount0` / `amount1` of fees to the setUp position: funds the pool and advances its fee growth
    /// by exactly the growth the upstream manager converts back into these amounts for the position's liquidity.
    function _accrueFees(uint256 amount0, uint256 amount1) internal {
        uint128 liquidity = pool.liquidityOf(pool.positionKey(address(npm), TICK_LOWER, TICK_UPPER));
        MockERC20Token(address(token0)).mint(address(pool), amount0);
        MockERC20Token(address(token1)).mint(address(pool), amount1);
        pool.accrueFeeGrowth(
            FullMath.mulDivRoundingUp(amount0, Q128, liquidity), FullMath.mulDivRoundingUp(amount1, Q128, liquidity)
        );
    }
}
