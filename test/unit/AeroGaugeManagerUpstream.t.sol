// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {GaugeManager} from "../../src/GaugeManager.sol";
import {IAeroGauge} from "../../src/interfaces/aero/IAeroGauge.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockNPM, MockVault, MockPool, MockSlipstreamFactory, MockERC20Token} from "./GaugeManager.t.sol";
import {LeafVoterFixture} from "../mocks/AeroDeliveryFixture.sol";

interface IInitializeGauge {
    function initialize(address, address, address, address, int24, bool) external;
    function deferredReferralEmissions(address) external view returns (uint256);
}

contract CollectingNPMFixture is MockNPM {
    constructor(address factory_, address weth_) MockNPM(factory_, weth_) {}

    function collect(INonfungiblePositionManager.CollectParams calldata) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

contract RewardGrowthPoolFixture is MockPool {
    uint256 public rewardGrowthGlobalX128;
    uint128 public stakedLiquidity;
    constructor(address a, address b) MockPool(a, b, 100) {}

    function setGrowth(uint256 value) external {
        rewardGrowthGlobalX128 = value;
    }

    function getRewardGrowthInside(int24, int24, uint256) external view returns (uint256) {
        return rewardGrowthGlobalX128;
    }

    function settleToBlock() external pure returns (uint256) {
        return 0;
    }

    function stake(int128 amount, int24, int24) external {
        if (amount > 0) stakedLiquidity += uint128(amount);
        else stakedLiquidity -= uint128(-amount);
    }
}

contract EmissionsVoterFixture is LeafVoterFixture {
    bool public mintFails;
    uint256 public forfeited;
    constructor(address token) LeafVoterFixture(token) {}

    function setMintFails(bool value) external {
        mintFails = value;
    }

    function projectedCumulativeRewardShare(address) external pure returns (uint256) {
        return 0;
    }

    function forfeitEmissions(uint128 amount) external {
        forfeited += amount;
    }

    function mintEmissions(address[] calldata recipients, uint128[] calldata amounts) external {
        require(!mintFails, "mint unavailable");
        for (uint256 i; i < recipients.length; ++i) {
            MockERC20Token(RECEIPT_TOKEN).mint(recipients[i], amounts[i]);
        }
    }
}

contract GaugeConfigFixture {
    uint256 public minBlocks;
    uint256 public penalty;
    address public referral;
    uint256 public referralShare;

    function setConfig(uint256 blocks_, uint256 penalty_, address referral_, uint256 share_) external {
        minBlocks = blocks_;
        penalty = penalty_;
        referral = referral_;
        referralShare = share_;
    }

    function effectivePenaltyConfig(address) external view returns (uint256, uint256) {
        return (minBlocks, penalty);
    }

    function referralConfig(address) external view returns (address, uint256) {
        return (referral, referralShare);
    }
}

/// @dev Executes the unmodified, pinned upstream CLGauge bytecode with controlled pool/voter/NPM dependencies.
/// This verifies upstream gauge semantics; it is not a full Aero deployment or production fork.
contract AeroGaugeManagerUpstreamTest is Test {
    uint256 constant Q128 = 1 << 128;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    MockERC20Token token;
    MockERC20Token usdc;
    CollectingNPMFixture npm;
    MockVault vault;
    RewardGrowthPoolFixture pool;
    EmissionsVoterFixture voter;
    GaugeConfigFixture config;
    IAeroGauge gauge;
    GaugeManager manager;

    function setUp() public {
        token = new MockERC20Token("Receipt", "rAERO");
        usdc = new MockERC20Token("USDC", "USDC");
        MockSlipstreamFactory factory = new MockSlipstreamFactory();
        pool = new RewardGrowthPoolFixture(address(token), address(usdc));
        factory.setPool(address(token), address(usdc), 100, address(pool));
        npm = new CollectingNPMFixture(address(factory), address(usdc));
        vault = new MockVault();
        voter = new EmissionsVoterFixture(address(token));
        config = new GaugeConfigFixture();
        gauge = IAeroGauge(
            deployCode(
                "fixtures/upstream-gauge/out/CLGauge.sol/CLGauge.json",
                abi.encode(address(voter), address(npm), address(config))
            )
        );
        address token0 = pool.token0();
        address token1 = pool.token1();
        vm.prank(address(config));
        IInitializeGauge(address(gauge)).initialize(address(pool), address(0), token0, token1, 100, true);
        pool.setGauge(address(gauge));
        manager = new GaugeManager(
            INonfungiblePositionManager(address(npm)),
            IERC20(address(token)),
            IVault(address(vault)),
            address(0),
            address(0)
        );
        manager.setGauge(address(pool), address(gauge));
        _stake(1, ALICE);
        _stake(2, BOB);
    }

    function _stake(uint256 id, address owner) private {
        npm.setPosition(id, address(token), address(usdc), 100, -60, 60, 10);
        npm.mint(address(vault), id);
        vault.setOwner(id, owner);
        vm.startPrank(address(vault));
        npm.approve(address(manager), id);
        manager.stakePosition(id);
        vm.stopPrank();
    }

    function _withdraw(uint256 id) private {
        vm.prank(address(vault));
        manager.unstakePosition(id);
    }

    function testUpstreamWithdrawDefersAndLaterClaimSeparatesOwners() public {
        pool.setGrowth(10 * Q128);
        voter.setMintFails(true);
        _withdraw(1);
        assertEq(npm.ownerOf(1), address(vault));
        assertEq(gauge.deferredEmissions(address(manager)), 100);
        assertEq(manager.deferredClaims(address(gauge), 0, ALICE), 100);
        pool.setGrowth(12 * Q128);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        assertEq(gauge.earned(address(manager), ids), 220);
        assertEq(manager.positionRewards(2), 120);
        voter.setMintFails(false);
        vm.prank(BOB);
        assertEq(manager.claimRewards(2, BOB), 120);
        assertEq(token.balanceOf(BOB), 120);
        assertEq(manager.reservedRewards(), 100);
        vm.prank(ALICE);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        assertEq(token.balanceOf(ALICE), 100);
    }

    function testUpstreamRecoveryWorksWithoutAnyStakedNFT() public {
        pool.setGrowth(10 * Q128);
        voter.setMintFails(true);
        _withdraw(1);
        _withdraw(2);
        assertEq(pool.stakedLiquidity(), 0);
        voter.setMintFails(false);
        manager.recoverDeferredRewards(address(gauge));
        vm.prank(ALICE);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        vm.prank(BOB);
        manager.claimDeferredRewards(address(gauge), 0, BOB);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(manager.reservedRewards(), 0);
    }

    function testUpstreamRecordsNetRewardAfterPenaltyAndReferral() public {
        config.setConfig(100, 200_000, address(0xCAFE), 100_000);
        pool.setGrowth(10 * Q128);
        voter.setMintFails(true);
        _withdraw(1);
        assertEq(manager.deferredClaims(address(gauge), 0, ALICE), 72);
        assertEq(voter.forfeited(), 20);
        assertEq(IInitializeGauge(address(gauge)).deferredReferralEmissions(address(0xCAFE)), 8);
        voter.setMintFails(false);
        vm.prank(ALICE);
        assertEq(manager.claimDeferredRewards(address(gauge), 0, ALICE), 72);
    }
}
