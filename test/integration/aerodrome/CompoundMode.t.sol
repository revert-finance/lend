// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./AerodromeTestBase.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";

/// A position's compound mode (Simple 10% / Advanced 2%) prices every compound of that position: the fee
/// auto-compound in AutoRangeAndCompound and the AERO reward compound in GaugeManager, which reads the mode rate
/// from AutoRangeAndCompound through its compound mode source.
contract CompoundModeTest is AerodromeTestBase {
    AutoRangeAndCompound public autoRange;
    address public token0;
    address public token1;

    uint256 internal constant FEES = 100e18;

    function setUp() public override {
        super.setUp();

        autoRange = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(npm)), admin, admin, 60, 200, address(0), address(0)
        );
        vault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vault));
        oracle.setMaxPoolPriceDifference(type(uint16).max);
        gaugeManager.setCompoundModeSource(address(autoRange));

        (token0, token1) =
            address(usdc) < address(dai) ? (address(usdc), address(dai)) : (address(dai), address(usdc));
        aero.mint(address(usdcDaiGauge), 100e18);
    }

    function _config() internal pure returns (AutoRangeAndCompound.PositionConfig memory) {
        return AutoRangeAndCompound.PositionConfig({
            lowerTickLimit: 0,
            upperTickLimit: 0,
            lowerTickDelta: 0,
            upperTickDelta: 0,
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            autoCompound: true,
            maxRewardX64: 0,
            autoCompoundMin0: 0,
            autoCompoundMin1: 0,
            autoCompoundRewardMin: 0
        });
    }

    /// Wallet-held position with fees to compound; the mock position manager reports collected fees without
    /// transferring them, so the transformer is funded with the same amounts.
    function _feePosition(AutoRangeAndCompound.CompoundMode mode) internal returns (uint256 tokenId) {
        tokenId = createPosition(alice, token0, token1, 1, -100, 100, 1000e18);
        npm.setTokensOwed(tokenId, uint128(FEES), uint128(FEES));
        MockERC20(token0).mint(address(autoRange), FEES);
        MockERC20(token1).mint(address(autoRange), FEES);
        vm.prank(alice);
        autoRange.configToken(tokenId, address(0), _config(), mode);
    }

    function _feeCompound(uint256 tokenId) internal {
        vm.prank(admin);
        autoRange.autoCompound(
            AutoRangeAndCompound.AutoCompoundParams({
                tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
            })
        );
    }

    /// Operator reward on a fee compound of `amount` per token at `rateX64`: the vault-style add leaves exactly the
    /// reward behind (maxAdd = amount * Q64 / (rate + Q64); reward = added * rate / Q64).
    function _expectedFee(uint256 amount, uint256 rateX64) internal pure returns (uint256) {
        uint256 added = amount * Q64 / (rateX64 + Q64);
        return added * rateX64 / Q64;
    }

    function testDefaultsAreTwoAndTenPercent() public {
        assertEq(autoRange.totalRewardX64(), uint64(Q64 / 50), "Advanced 2%");
        assertEq(autoRange.simpleRewardX64(), uint64(Q64 / 10), "Simple 10%");
        assertEq(autoRange.MAX_REWARD_X64(), uint64(Q64 / 10));
        assertEq(gaugeManager.MAX_REWARD_X64(), uint64(Q64 / 10));
        assertEq(gaugeManager.totalRewardX64(), uint64(Q64 / 50), "GaugeManager fallback 2%");
    }

    function testFeeCompoundChargesTenPercentInSimpleMode() public {
        uint256 tokenId = _feePosition(AutoRangeAndCompound.CompoundMode.Simple);
        assertEq(autoRange.compoundRewardX64(tokenId), autoRange.simpleRewardX64());

        _feeCompound(tokenId);

        uint256 fee = _expectedFee(FEES, Q64 / 10);
        assertEq(IERC20(token0).balanceOf(address(autoRange)), fee, "10% of the compounded token0");
        assertEq(IERC20(token1).balanceOf(address(autoRange)), fee, "10% of the compounded token1");
        assertApproxEqRel(fee * 11, FEES, 1e12, "reward is a tenth of what went into the position");
    }

    function testFeeCompoundChargesTwoPercentInAdvancedMode() public {
        uint256 tokenId = _feePosition(AutoRangeAndCompound.CompoundMode.Advanced);
        assertEq(autoRange.compoundRewardX64(tokenId), autoRange.totalRewardX64());

        _feeCompound(tokenId);

        uint256 fee = _expectedFee(FEES, Q64 / 50);
        assertEq(IERC20(token0).balanceOf(address(autoRange)), fee, "2% of the compounded token0");
        assertEq(IERC20(token1).balanceOf(address(autoRange)), fee, "2% of the compounded token1");
    }

    /// An unconfigured position is Advanced: the default of the enum keeps today's 2%.
    function testUnconfiguredPositionIsAdvanced() public {
        assertEq(autoRange.compoundRewardX64(123456), autoRange.totalRewardX64());
    }

    /// Staked position compounding AERO rewards through a vault transform: GaugeManager charges the mode rate.
    function _stakedPosition(AutoRangeAndCompound.CompoundMode mode) internal returns (uint256 tokenId) {
        tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.stakePosition(tokenId);
        vault.approveTransform(tokenId, admin, true);
        vault.approveTransform(tokenId, address(autoRange), true);
        autoRange.configToken(tokenId, address(vault), _config(), mode);
        vm.stopPrank();

        usdcDaiGauge.setReward(tokenId, 10e18); // 10 AERO, swapped 50/50 at 1:1 by the mock pools
        npm.setTokensOwed(tokenId, 0, 0); // no fees: only the reward compound pays a fee
    }

    function _rewardCompound(uint256 tokenId) internal {
        vm.prank(admin);
        vault.transform(
            tokenId,
            address(autoRange),
            abi.encodeCall(
                AutoRangeAndCompound.autoCompound,
                (
                    AutoRangeAndCompound.AutoCompoundParams({
                        tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
                    })
                )
            )
        );
    }

    function testRewardCompoundChargesTenPercentInSimpleMode() public {
        uint256 tokenId = _stakedPosition(AutoRangeAndCompound.CompoundMode.Simple);

        _rewardCompound(tokenId);

        uint256 fee = _expectedFee(5e18, Q64 / 10);
        assertGt(fee, 0);
        assertEq(usdc.balanceOf(address(gaugeManager)), fee, "10% of the USDC added from AERO");
        assertEq(dai.balanceOf(address(gaugeManager)), fee, "10% of the DAI added from AERO");
    }

    function testRewardCompoundChargesTwoPercentInAdvancedMode() public {
        uint256 tokenId = _stakedPosition(AutoRangeAndCompound.CompoundMode.Advanced);

        _rewardCompound(tokenId);

        uint256 fee = _expectedFee(5e18, Q64 / 50);
        assertEq(usdc.balanceOf(address(gaugeManager)), fee, "2% of the USDC added from AERO");
        assertEq(dai.balanceOf(address(gaugeManager)), fee, "2% of the DAI added from AERO");
    }

    /// Without a source GaugeManager cannot see the mode and charges its fallback rate.
    function testRewardCompoundWithoutSourceChargesTheFallback() public {
        gaugeManager.setCompoundModeSource(address(0));
        uint256 tokenId = _stakedPosition(AutoRangeAndCompound.CompoundMode.Simple);

        _rewardCompound(tokenId);

        uint256 fee = _expectedFee(5e18, uint256(gaugeManager.totalRewardX64()));
        assertEq(usdc.balanceOf(address(gaugeManager)), fee);
        assertEq(dai.balanceOf(address(gaugeManager)), fee);
    }

    /// The Simple rate can only be lowered, like the Advanced one.
    function testSimpleRewardCanOnlyBeLowered() public {
        uint64 current = autoRange.simpleRewardX64();
        uint64 advanced = autoRange.totalRewardX64();
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRange.setAutoCompoundRewards(advanced, current + 1);
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRange.setAutoCompoundRewards(advanced + 1, current);

        autoRange.setAutoCompoundRewards(advanced, current / 2);
        assertEq(autoRange.simpleRewardX64(), current / 2);
        assertEq(autoRange.totalRewardX64(), advanced);

        uint256 tokenId = _feePosition(AutoRangeAndCompound.CompoundMode.Simple);
        assertEq(autoRange.compoundRewardX64(tokenId), current / 2, "mode rate follows the setting");
    }
}
