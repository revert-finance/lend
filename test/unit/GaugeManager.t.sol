// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../src/GaugeManager.sol";
import "../../src/utils/Constants.sol";

contract MockERC20Token is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSlipstreamFactory {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        pools[_key(tokenA, tokenB, tickSpacing)] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        return pools[_key(tokenA, tokenB, tickSpacing)];
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, int24(fee))];
    }

    function _key(address tokenA, address tokenB, int24 tickSpacing) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenA, tokenB, tickSpacing));
    }
}

contract MockPool {
    address public gauge;

    function setGauge(address _gauge) external {
        gauge = _gauge;
    }
}

contract MockVault is IERC721Receiver {
    mapping(uint256 => address) public owners;

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract MockAllowanceHolder {
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        if (amountIn != 0) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        }
        if (amountOut != 0) {
            IERC20(tokenOut).transfer(msg.sender, amountOut);
        }
    }
}

contract MockNPM is ERC721 {
    struct Position {
        address token0;
        address token1;
        uint24 feeOrTickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    address public immutable factory;
    address public immutable WETH9;

    mapping(uint256 => Position) internal positionData;

    uint256 public nextAdded0;
    uint256 public nextAdded1;

    constructor(address _factory, address _weth) ERC721("Mock NPM", "MNPM") {
        factory = _factory;
        WETH9 = _weth;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function setPosition(
        uint256 tokenId,
        address token0,
        address token1,
        uint24 feeOrTickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        positionData[tokenId] = Position({
            token0: token0,
            token1: token1,
            feeOrTickSpacing: feeOrTickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity
        });
    }

    function setNextIncreaseLiquidityResult(uint256 amount0, uint256 amount1) external {
        nextAdded0 = amount0;
        nextAdded1 = amount1;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        Position memory position = positionData[tokenId];
        return (
            0,
            address(0),
            position.token0,
            position.token1,
            position.feeOrTickSpacing,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            0,
            0,
            0,
            0
        );
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage position = positionData[params.tokenId];
        amount0 = nextAdded0 == 0 ? params.amount0Desired : Math.min(params.amount0Desired, nextAdded0);
        amount1 = nextAdded1 == 0 ? params.amount1Desired : Math.min(params.amount1Desired, nextAdded1);

        if (amount0 != 0) {
            IERC20(position.token0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 != 0) {
            IERC20(position.token1).transferFrom(msg.sender, address(this), amount1);
        }

        nextAdded0 = 0;
        nextAdded1 = 0;
        liquidity = amount0 + amount1 == 0 ? 0 : 1;
        position.liquidity = position.liquidity + liquidity;
    }
}

contract MockGauge is IGauge {
    IERC721 public immutable nft;
    IERC20 public immutable rewardToken;

    mapping(uint256 => address) public staker;
    mapping(uint256 => uint256) public rewardPerTokenId;
    bool public revertOnGetReward;

    constructor(IERC721 _nft, IERC20 _rewardToken) {
        nft = _nft;
        rewardToken = _rewardToken;
    }

    function setReward(uint256 tokenId, uint256 amount) external {
        rewardPerTokenId[tokenId] = amount;
    }

    function setRevertOnGetReward(bool value) external {
        revertOnGetReward = value;
    }

    function deposit(uint256 tokenId) external override {
        nft.transferFrom(msg.sender, address(this), tokenId);
        staker[tokenId] = msg.sender;
    }

    function withdraw(uint256 tokenId) external override {
        if (staker[tokenId] != msg.sender) {
            revert("not staker");
        }
        delete staker[tokenId];
        nft.transferFrom(address(this), msg.sender, tokenId);
    }

    function getReward(uint256 tokenId) external override {
        if (revertOnGetReward) {
            revert("reward revert");
        }
        if (staker[tokenId] == address(0)) {
            revert("not staked");
        }
        uint256 reward = rewardPerTokenId[tokenId];
        rewardPerTokenId[tokenId] = 0;
        if (reward != 0) {
            rewardToken.transfer(msg.sender, reward);
        }
    }
}

contract GaugeManagerUnitTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    address internal constant ALICE = address(0xA11CE);
    address internal constant RECIPIENT = address(0xBEEF);

    MockERC20Token internal aero;
    MockERC20Token internal token0;
    MockERC20Token internal token1;
    MockSlipstreamFactory internal factory;
    MockPool internal pool;
    MockNPM internal npm;
    MockGauge internal gauge;
    MockVault internal vault;
    MockAllowanceHolder internal allowanceHolder;
    GaugeManager internal gaugeManager;

    function setUp() external {
        aero = new MockERC20Token("AERO", "AERO");
        token0 = new MockERC20Token("Token0", "TK0");
        token1 = new MockERC20Token("Token1", "TK1");

        factory = new MockSlipstreamFactory();
        pool = new MockPool();
        npm = new MockNPM(address(factory), address(0xC0FFEE));
        gauge = new MockGauge(IERC721(address(npm)), IERC20(address(aero)));
        vault = new MockVault();
        allowanceHolder = new MockAllowanceHolder();

        pool.setGauge(address(gauge));
        factory.setPool(address(token0), address(token1), 100, address(pool));

        gaugeManager = new GaugeManager(
            INonfungiblePositionManager(address(npm)),
            IERC20(address(aero)),
            IVault(address(vault)),
            address(0),
            address(allowanceHolder)
        );
        assertEq(gaugeManager.withdrawer(), address(this));
        gaugeManager.setGauge(address(pool), address(gauge));

        npm.setPosition(TOKEN_ID, address(token0), address(token1), 100, -60, 60, 10);
        npm.mint(address(vault), TOKEN_ID);
        vault.setOwner(TOKEN_ID, ALICE);

        vm.prank(address(vault));
        npm.approve(address(gaugeManager), TOKEN_ID);
    }

    function testClaimRewardsFromVault() external {
        _stake();

        aero.mint(address(gauge), 10 ether);
        gauge.setReward(TOKEN_ID, 10 ether);

        uint256 before = aero.balanceOf(RECIPIENT);
        vm.prank(address(vault));
        uint256 claimed = gaugeManager.claimRewards(TOKEN_ID, RECIPIENT);

        assertEq(claimed, 10 ether);
        assertEq(aero.balanceOf(RECIPIENT) - before, 10 ether);
    }

    function testClaimRewardsFromOwnerDirectly() external {
        _stake();

        aero.mint(address(gauge), 10 ether);
        gauge.setReward(TOKEN_ID, 10 ether);

        uint256 before = aero.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 claimed = gaugeManager.claimRewards(TOKEN_ID, ALICE);

        assertEq(claimed, 10 ether);
        assertEq(aero.balanceOf(ALICE) - before, 10 ether);
    }

    function testClaimRewardsDefaultsRecipientToOwnerWhenZeroAddress() external {
        _stake();

        aero.mint(address(gauge), 10 ether);
        gauge.setReward(TOKEN_ID, 10 ether);

        uint256 before = aero.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 claimed = gaugeManager.claimRewards(TOKEN_ID, address(0));

        assertEq(claimed, 10 ether);
        assertEq(aero.balanceOf(ALICE) - before, 10 ether);
    }

    function testCompoundRewardsSwapsAddsLiquidityAndSendsLeftovers() external {
        _stake();

        uint256 claimedAero = 100 ether;
        uint256 rewardX64 = gaugeManager.totalRewardX64();
        uint256 q64 = 2 ** 64;

        aero.mint(address(gauge), claimedAero);
        gauge.setReward(TOKEN_ID, claimedAero);

        token0.mint(address(allowanceHolder), 1_000 ether);
        token1.mint(address(allowanceHolder), 1_000 ether);

        npm.setNextIncreaseLiquidityResult(30 ether, 40 ether);

        bytes memory swapData0 =
            abi.encodeCall(MockAllowanceHolder.executeSwap, (address(aero), address(token0), 20 ether, 50 ether));
        bytes memory swapData1 =
            abi.encodeCall(MockAllowanceHolder.executeSwap, (address(aero), address(token1), 30 ether, 70 ether));

        uint256 aeroBefore = aero.balanceOf(ALICE);
        uint256 token0Before = token0.balanceOf(ALICE);
        uint256 token1Before = token1.balanceOf(ALICE);

        vm.prank(address(vault));
        (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) =
            gaugeManager.compoundRewards(TOKEN_ID, swapData0, swapData1, 0, 0, 4_000, block.timestamp + 1);

        uint256 rewardAmount0 = amountAdded0 * rewardX64 / q64;
        uint256 rewardAmount1 = amountAdded1 * rewardX64 / q64;

        assertEq(aeroAmount, claimedAero);
        assertEq(amountAdded0, 30 ether);
        assertEq(amountAdded1, 40 ether);

        assertEq(aero.balanceOf(ALICE) - aeroBefore, claimedAero - 50 ether);
        assertEq(aero.balanceOf(RECIPIENT), 0);
        assertEq(token0.balanceOf(ALICE) - token0Before, 50 ether - amountAdded0 - rewardAmount0);
        assertEq(token1.balanceOf(ALICE) - token1Before, 70 ether - amountAdded1 - rewardAmount1);
        assertEq(token0.balanceOf(address(gaugeManager)), rewardAmount0);
        assertEq(token1.balanceOf(address(gaugeManager)), rewardAmount1);
        assertEq(token0.balanceOf(RECIPIENT), 0);
        assertEq(token1.balanceOf(RECIPIENT), 0);

        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(gauge));
        assertEq(npm.ownerOf(TOKEN_ID), address(gauge));
        assertEq(gauge.staker(TOKEN_ID), address(gaugeManager));
    }

    function testCompoundRewardsFromOwnerDirectly() external {
        _stake();

        uint256 claimedAero = 100 ether;
        uint256 rewardX64 = gaugeManager.totalRewardX64();
        uint256 q64 = 2 ** 64;

        aero.mint(address(gauge), claimedAero);
        gauge.setReward(TOKEN_ID, claimedAero);
        token0.mint(address(allowanceHolder), 1_000 ether);
        token1.mint(address(allowanceHolder), 1_000 ether);

        bytes memory swapData0 =
            abi.encodeCall(MockAllowanceHolder.executeSwap, (address(aero), address(token0), 30 ether, 60 ether));
        bytes memory swapData1 =
            abi.encodeCall(MockAllowanceHolder.executeSwap, (address(aero), address(token1), 30 ether, 60 ether));

        vm.prank(ALICE);
        (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) =
            gaugeManager.compoundRewards(TOKEN_ID, swapData0, swapData1, 0, 0, 5_000, block.timestamp + 1);

        uint256 rewardAmount0 = amountAdded0 * rewardX64 / q64;
        uint256 rewardAmount1 = amountAdded1 * rewardX64 / q64;
        uint256 expectedAdded = 60 ether * q64 / (q64 + rewardX64);

        assertEq(aeroAmount, claimedAero);
        assertEq(amountAdded0, expectedAdded);
        assertEq(amountAdded1, expectedAdded);
        assertEq(aero.balanceOf(ALICE), claimedAero - 60 ether);
        assertEq(aero.balanceOf(RECIPIENT), 0);
        assertEq(token0.balanceOf(address(gaugeManager)), rewardAmount0);
        assertEq(token1.balanceOf(address(gaugeManager)), rewardAmount1);
        assertEq(token0.balanceOf(RECIPIENT), 0);
        assertEq(token1.balanceOf(RECIPIENT), 0);
        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(gauge));
        assertEq(npm.ownerOf(TOKEN_ID), address(gauge));
    }

    function testCompoundRewardsUsesUnswappedAeroWhenTokenIsInPair() external {
        uint256 tokenId = 3;
        npm.setPosition(tokenId, address(aero), address(token1), 100, -60, 60, 10);
        npm.mint(address(vault), tokenId);
        vault.setOwner(tokenId, ALICE);
        factory.setPool(address(aero), address(token1), 100, address(pool));

        vm.prank(address(vault));
        npm.approve(address(gaugeManager), tokenId);
        vm.prank(address(vault));
        gaugeManager.stakePosition(tokenId);

        uint256 claimedAero = 100 ether;

        aero.mint(address(gauge), claimedAero);
        gauge.setReward(tokenId, claimedAero);
        token1.mint(address(allowanceHolder), 1_000 ether);

        bytes memory swapData1 =
            abi.encodeCall(MockAllowanceHolder.executeSwap, (address(aero), address(token1), 40 ether, 80 ether));

        uint256 aeroBefore = aero.balanceOf(ALICE);
        uint256 token1Before = token1.balanceOf(ALICE);

        vm.prank(address(vault));
        (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) =
            gaugeManager.compoundRewards(tokenId, "", swapData1, 0, 0, 0, block.timestamp + 1);

        uint256 rewardX64 = gaugeManager.totalRewardX64();
        uint256 q64 = 2 ** 64;
        uint256 rewardAmount0 = amountAdded0 * rewardX64 / q64;
        uint256 rewardAmount1 = amountAdded1 * rewardX64 / q64;

        assertEq(aeroAmount, claimedAero);
        assertEq(amountAdded0, 60 ether * q64 / (q64 + rewardX64));
        assertEq(amountAdded1, 80 ether * q64 / (q64 + rewardX64));
        assertEq(aero.balanceOf(ALICE) - aeroBefore, 60 ether - amountAdded0 - rewardAmount0);
        assertEq(token1.balanceOf(ALICE) - token1Before, 80 ether - amountAdded1 - rewardAmount1);
        assertEq(aero.balanceOf(address(gaugeManager)), rewardAmount0);
        assertEq(token1.balanceOf(address(gaugeManager)), rewardAmount1);
        assertEq(aero.balanceOf(RECIPIENT), 0);
        assertEq(token1.balanceOf(RECIPIENT), 0);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(gauge));
    }

    function testSetGaugeRevertsForPoolGaugeMismatch() external {
        MockPool otherPool = new MockPool();
        otherPool.setGauge(address(0x1234));

        vm.expectRevert(Constants.InvalidPool.selector);
        gaugeManager.setGauge(address(otherPool), address(gauge));
    }

    function testStakeRevertsWhenCallerIsNotVault() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.stakePosition(TOKEN_ID);
    }

    function testStakeRevertsWhenGaugeIsNotConfigured() external {
        uint256 tokenId = 2;
        npm.setPosition(tokenId, address(token0), address(token1), 500, -60, 60, 10);
        npm.mint(address(vault), tokenId);
        vault.setOwner(tokenId, ALICE);

        vm.prank(address(vault));
        npm.approve(address(gaugeManager), tokenId);

        vm.prank(address(vault));
        vm.expectRevert(Constants.NotConfigured.selector);
        gaugeManager.stakePosition(tokenId);
    }

    function testStakeRevertsWhenAlreadyStaked() external {
        _stake();

        vm.prank(address(vault));
        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.stakePosition(TOKEN_ID);
    }

    function testUnstakeRevertsWhenNotStaked() external {
        vm.prank(address(vault));
        vm.expectRevert(Constants.NotStaked.selector);
        gaugeManager.unstakePosition(TOKEN_ID);
    }

    function testUnstakeSucceedsWhenGetRewardReverts() external {
        _stake();
        gauge.setRevertOnGetReward(true);

        vm.prank(address(vault));
        gaugeManager.unstakePosition(TOKEN_ID);

        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(0));
        assertEq(npm.ownerOf(TOKEN_ID), address(vault));
    }

    function testUnstakeRevertsWhenCallerIsNotVault() external {
        _stake();

        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.unstakePosition(TOKEN_ID);
    }

    function testUnstakeIfStakedReturnsFalseWhenNotStaked() external {
        vm.prank(address(vault));
        bool wasStaked = gaugeManager.unstakeIfStaked(TOKEN_ID);
        assertFalse(wasStaked);
    }

    function testUnstakeIfStakedReturnsTrueWhenStaked() external {
        _stake();

        vm.prank(address(vault));
        bool wasStaked = gaugeManager.unstakeIfStaked(TOKEN_ID);

        assertTrue(wasStaked);
        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(0));
        assertEq(npm.ownerOf(TOKEN_ID), address(vault));
    }

    function testUnstakeIfStakedSucceedsWhenGetRewardReverts() external {
        _stake();
        gauge.setRevertOnGetReward(true);

        vm.prank(address(vault));
        bool wasStaked = gaugeManager.unstakeIfStaked(TOKEN_ID);

        assertTrue(wasStaked);
        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(0));
        assertEq(npm.ownerOf(TOKEN_ID), address(vault));
    }

    function testUnstakeIfStakedRevertsWhenCallerIsNotVault() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.unstakeIfStaked(TOKEN_ID);
    }

    function testClaimRewardsRevertsWhenNotStaked() external {
        vm.prank(address(vault));
        vm.expectRevert(Constants.NotStaked.selector);
        gaugeManager.claimRewards(TOKEN_ID, RECIPIENT);
    }

    function testClaimRewardsRevertsWhenCallerIsNotVaultOrOwner() external {
        _stake();

        vm.prank(RECIPIENT);
        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.claimRewards(TOKEN_ID, RECIPIENT);
    }

    function testClaimRewardsRevertsWhenGaugeGetRewardReverts() external {
        _stake();
        gauge.setRevertOnGetReward(true);

        vm.prank(address(vault));
        vm.expectRevert(bytes("reward revert"));
        gaugeManager.claimRewards(TOKEN_ID, RECIPIENT);
    }

    function testCompoundRewardsRevertsOnInvalidSplit() external {
        _stake();

        vm.prank(address(vault));
        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.compoundRewards(TOKEN_ID, "", "", 0, 0, 10_001, block.timestamp + 1);
    }

    function testCompoundRewardsRevertsWhenCallerIsNotVaultOrOwner() external {
        _stake();

        vm.prank(RECIPIENT);
        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.compoundRewards(TOKEN_ID, "", "", 0, 0, 0, block.timestamp + 1);
    }

    function testCompoundRewardsReturnsZeroWhenNoRewards() external {
        _stake();

        vm.prank(address(vault));
        (uint256 aeroAmount, uint256 amountAdded0, uint256 amountAdded1) =
            gaugeManager.compoundRewards(TOKEN_ID, "", "", 0, 0, 0, block.timestamp + 1);

        assertEq(aeroAmount, 0);
        assertEq(amountAdded0, 0);
        assertEq(amountAdded1, 0);
        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(gauge));
        assertEq(npm.ownerOf(TOKEN_ID), address(gauge));
    }

    function testSetCompoundRewardOnlyAllowsLowerValues() external {
        uint64 currentRewardX64 = gaugeManager.totalRewardX64();

        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.setCompoundReward(currentRewardX64 + 1);

        gaugeManager.setCompoundReward(currentRewardX64 / 2);
        assertEq(gaugeManager.totalRewardX64(), currentRewardX64 / 2);
    }

    function testSetWithdrawerRevertsForZeroAddress() external {
        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.setWithdrawer(address(0));
    }

    function testWithdrawBalancesOnlyAllowedForWithdrawer() external {
        token0.mint(address(gaugeManager), 7 ether);
        token1.mint(address(gaugeManager), 11 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        vm.prank(ALICE);
        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.withdrawBalances(tokens, ALICE);

        gaugeManager.setWithdrawer(RECIPIENT);
        vm.prank(RECIPIENT);
        gaugeManager.withdrawBalances(tokens, ALICE);

        assertEq(token0.balanceOf(ALICE), 7 ether);
        assertEq(token1.balanceOf(ALICE), 11 ether);
        assertEq(token0.balanceOf(address(gaugeManager)), 0);
        assertEq(token1.balanceOf(address(gaugeManager)), 0);
    }

    function testWithdrawETHOnlyAllowedForWithdrawer() external {
        vm.deal(address(gaugeManager), 1 ether);

        vm.prank(ALICE);
        vm.expectRevert(Constants.Unauthorized.selector);
        gaugeManager.withdrawETH(ALICE);

        uint256 aliceBefore = ALICE.balance;
        gaugeManager.setWithdrawer(RECIPIENT);
        vm.prank(RECIPIENT);
        gaugeManager.withdrawETH(ALICE);

        assertEq(ALICE.balance - aliceBefore, 1 ether);
        assertEq(address(gaugeManager).balance, 0);
    }

    function _stake() internal {
        vm.prank(address(vault));
        gaugeManager.stakePosition(TOKEN_ID);
        assertEq(gaugeManager.tokenIdToGauge(TOKEN_ID), address(gauge));
        assertEq(npm.ownerOf(TOKEN_ID), address(gauge));
    }
}
