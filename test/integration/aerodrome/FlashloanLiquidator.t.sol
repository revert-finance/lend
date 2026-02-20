// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../../src/utils/FlashloanLiquidator.sol";
import "../../../src/interfaces/IVault.sol";
import "./AerodromeTestBase.sol";

contract MockFlashVault {
    IERC20 public immutable assetToken;
    uint256 public liquidationCost;
    uint256 public liquidationValue;

    constructor(IERC20 _assetToken, uint256 _liquidationCost, uint256 _liquidationValue) {
        assetToken = _assetToken;
        liquidationCost = _liquidationCost;
        liquidationValue = _liquidationValue;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function loanInfo(uint256)
        external
        view
        returns (uint256 debt, uint256 fullValue, uint256 collateralValue, uint256 _liquidationCost, uint256 _liquidationValue)
    {
        return (0, 0, 0, liquidationCost, liquidationValue);
    }

    function liquidate(IVault.LiquidateParams calldata params) external returns (uint256 amount0, uint256 amount1) {
        // Pull flash-loaned asset from caller (FlashloanLiquidator) and immediately return it to allow repayment.
        assetToken.transferFrom(msg.sender, address(this), liquidationCost);
        assetToken.transfer(msg.sender, liquidationCost);

        // Params are not otherwise used for this callback-hardening test.
        params;
        return (0, 0);
    }
}

contract MockFlashLoanPool {
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint24 public immutable fee;

    constructor(IERC20 _token0, IERC20 _token1, uint24 _fee) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
    }

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external {
        uint256 bal0Before = token0.balanceOf(address(this));
        uint256 bal1Before = token1.balanceOf(address(this));

        if (amount0 != 0) token0.transfer(recipient, amount0);
        if (amount1 != 0) token1.transfer(recipient, amount1);

        IUniswapV3FlashCallback(recipient).uniswapV3FlashCallback(0, 0, data);

        // Ensure loan is repaid (no fees in this mock).
        require(token0.balanceOf(address(this)) >= bal0Before, "not repaid 0");
        require(token1.balanceOf(address(this)) >= bal1Before, "not repaid 1");
    }
}

contract FlashloanLiquidatorCallbackTest is AerodromeTestBase {
    function testFlashCallbackRejectsDirectCall() public {
        FlashloanLiquidator liquidator = new FlashloanLiquidator(npm, address(0), address(0));

        vm.expectRevert(Unauthorized.selector);
        liquidator.uniswapV3FlashCallback(0, 0, bytes("anything"));
    }

    function testLiquidateOnlyAcceptsCallbackFromActivePoolAndData() public {
        FlashloanLiquidator liquidator = new FlashloanLiquidator(npm, address(0), address(0));

        // Create a tokenId so FlashloanLiquidator can read token0/token1 for swap params.
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1);

        uint256 cost = 100e6;
        MockFlashVault vault = new MockFlashVault(IERC20(address(usdc)), cost, 1);
        MockFlashLoanPool pool = new MockFlashLoanPool(IERC20(address(usdc)), IERC20(address(weth)), 1);

        // Make Swapper._getPool(poolToken0,poolToken1,fee) resolve to this pool (Aerodrome factory path).
        factory.setPool(address(usdc), address(weth), int24(uint24(pool.fee())), address(pool));

        // Fund pool with USDC for the flash loan.
        usdc.mint(address(pool), cost);

        FlashloanLiquidator.LiquidateParams memory params = FlashloanLiquidator.LiquidateParams({
            tokenId: tokenId,
            vault: IVault(address(vault)),
            flashLoanPool: IUniswapV3Pool(address(pool)),
            amount0In: 0,
            swapData0: "",
            amount1In: 0,
            swapData1: "",
            minReward: 0,
            deadline: block.timestamp + 1 hours
        });

        liquidator.liquidate(params);
    }
}

