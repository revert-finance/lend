// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../src/PancakeStakingManager.sol";
import "../../src/interfaces/pancake/IPancakeV3SwapCallback.sol";
import "../../src/utils/Constants.sol";

contract MockPancakeERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPancakeFactory {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function _key(address tokenA, address tokenB, uint24 fee) internal pure returns (bytes32) {
        return tokenA < tokenB ? keccak256(abi.encode(tokenA, tokenB, fee)) : keccak256(abi.encode(tokenB, tokenA, fee));
    }
}

contract MockPancakePool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    uint160 public sqrtPriceX96 = 79228162514264337593543950336;
    int24 public tick;
    int24 public observedTick;
    uint16 public observationIndex;
    uint16 public observationCardinality = 10;
    uint16 public observationCardinalityNext = 10;
    uint32 public feeProtocol;
    bool public unlocked = true;
    uint16 public outputBps = 10_000;

    constructor(address tokenA, address tokenB, uint24 _fee) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = _fee;
        tickSpacing = 1;
    }

    function setTick(int24 _tick) external {
        tick = _tick;
    }

    function setObservedTick(int24 _tick) external {
        observedTick = _tick;
    }

    function setOutputBps(uint16 _outputBps) external {
        outputBps = _outputBps;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96_,
            int24 tick_,
            uint16 observationIndex_,
            uint16 observationCardinality_,
            uint16 observationCardinalityNext_,
            uint32 feeProtocol_,
            bool unlocked_
        )
    {
        return (
            sqrtPriceX96,
            tick,
            observationIndex,
            observationCardinality,
            observationCardinalityNext,
            feeProtocol,
            unlocked
        );
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn = uint256(amountSpecified);
        uint256 amountOut = amountIn * outputBps / 10_000;

        if (zeroForOne) {
            IERC20(token1).transfer(recipient, amountOut);
            IPancakeV3SwapCallback(msg.sender).pancakeV3SwapCallback(int256(amountIn), -int256(amountOut), data);
            return (int256(amountIn), -int256(amountOut));
        }

        IERC20(token0).transfer(recipient, amountOut);
        IPancakeV3SwapCallback(msg.sender).pancakeV3SwapCallback(-int256(amountOut), int256(amountIn), data);
        return (-int256(amountOut), int256(amountIn));
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityPostWriteX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityPostWriteX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = int56(observedTick) * int56(uint56(secondsAgos[i]));
        }
    }
}

contract MockPancakeVault is IERC721Receiver {
    mapping(uint256 => address) public owners;
    mapping(uint256 => uint256) public loans;

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function setDebtShares(uint256 tokenId, uint256 debtShares) external {
        loans[tokenId] = debtShares;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract MockPancakeNPM is ERC721 {
    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    address public immutable deployer;
    address public immutable factory;
    address public immutable WETH9;

    mapping(uint256 => Position) internal positionData;

    constructor(address _factory, address _weth) ERC721("Mock Pancake NPM", "MPNPM") {
        deployer = address(0xCAFE);
        factory = _factory;
        WETH9 = _weth;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function setPosition(
        uint256 tokenId,
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        positionData[tokenId] = Position(token0, token1, fee, tickLower, tickUpper, liquidity);
    }

    function addLiquidity(uint256 tokenId, uint128 liquidity) external {
        positionData[tokenId].liquidity += liquidity;
    }

    function removeLiquidity(uint256 tokenId, uint128 liquidity) external {
        positionData[tokenId].liquidity -= liquidity;
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
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            0,
            0,
            0,
            0
        );
    }
}

contract MockPancakeMasterChef is IERC721Receiver {
    address public immutable CAKE;
    address public immutable nonfungiblePositionManager;

    struct PoolInfo {
        uint256 allocPoint;
        IUniswapV3Pool v3Pool;
        address token0;
        address token1;
        uint24 fee;
        uint256 totalLiquidity;
        uint256 totalBoostLiquidity;
    }

    mapping(uint256 => PoolInfo) internal pools;
    mapping(address => uint256) public v3PoolAddressPid;
    mapping(uint256 => address) public staker;
    mapping(uint256 => uint256) public rewardPerTokenId;

    uint256 public nextAdded0;
    uint256 public nextAdded1;
    uint256 public nextDecreased0;
    uint256 public nextDecreased1;

    mapping(uint256 => uint256) public owed0;
    mapping(uint256 => uint256) public owed1;

    constructor(address cake, address npm) {
        CAKE = cake;
        nonfungiblePositionManager = npm;
    }

    function addPool(uint256 pid, IUniswapV3Pool pool) external {
        pools[pid] = PoolInfo({
            allocPoint: 1,
            v3Pool: pool,
            token0: pool.token0(),
            token1: pool.token1(),
            fee: pool.fee(),
            totalLiquidity: 0,
            totalBoostLiquidity: 0
        });
        v3PoolAddressPid[address(pool)] = pid;
    }

    function poolInfo(uint256 pid)
        external
        view
        returns (
            uint256 allocPoint,
            IUniswapV3Pool v3Pool,
            address token0,
            address token1,
            uint24 fee,
            uint256 totalLiquidity,
            uint256 totalBoostLiquidity
        )
    {
        PoolInfo memory pool = pools[pid];
        return (
            pool.allocPoint,
            pool.v3Pool,
            pool.token0,
            pool.token1,
            pool.fee,
            pool.totalLiquidity,
            pool.totalBoostLiquidity
        );
    }

    function setReward(uint256 tokenId, uint256 amount) external {
        rewardPerTokenId[tokenId] = amount;
    }

    function setNextIncreaseLiquidityResult(uint256 amount0, uint256 amount1) external {
        nextAdded0 = amount0;
        nextAdded1 = amount1;
    }

    function setNextDecreaseLiquidityResult(uint256 amount0, uint256 amount1) external {
        nextDecreased0 = amount0;
        nextDecreased1 = amount1;
    }

    function pendingCake(uint256 tokenId) external view returns (uint256 reward) {
        return rewardPerTokenId[tokenId];
    }

    function harvest(uint256 tokenId, address to) external returns (uint256 reward) {
        if (staker[tokenId] != msg.sender) {
            revert("not staker");
        }
        reward = rewardPerTokenId[tokenId];
        rewardPerTokenId[tokenId] = 0;
        if (reward != 0) {
            IERC20(CAKE).transfer(to, reward);
        }
    }

    function withdraw(uint256 tokenId, address to) external returns (uint256 reward) {
        if (staker[tokenId] != msg.sender) {
            revert("not staker");
        }
        reward = rewardPerTokenId[tokenId];
        rewardPerTokenId[tokenId] = 0;
        if (reward != 0) {
            IERC20(CAKE).transfer(to, reward);
        }
        delete staker[tokenId];
        IERC721(nonfungiblePositionManager).safeTransferFrom(address(this), to, tokenId);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (staker[params.tokenId] == address(0)) {
            revert("not staked");
        }

        (,, address token0, address token1,,,,,,,,) =
            MockPancakeNPM(nonfungiblePositionManager).positions(params.tokenId);
        amount0 = nextAdded0 == 0 ? params.amount0Desired : Math.min(params.amount0Desired, nextAdded0);
        amount1 = nextAdded1 == 0 ? params.amount1Desired : Math.min(params.amount1Desired, nextAdded1);

        if (amount0 != 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 != 0) {
            IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        }

        nextAdded0 = 0;
        nextAdded1 = 0;
        liquidity = amount0 + amount1 == 0 ? 0 : 1;
        MockPancakeNPM(nonfungiblePositionManager).addLiquidity(params.tokenId, liquidity);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (staker[params.tokenId] != msg.sender) {
            revert("not staker");
        }
        amount0 = nextDecreased0;
        amount1 = nextDecreased1;
        owed0[params.tokenId] += amount0;
        owed1[params.tokenId] += amount1;
        nextDecreased0 = 0;
        nextDecreased1 = 0;
        MockPancakeNPM(nonfungiblePositionManager).removeLiquidity(params.tokenId, params.liquidity);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (staker[params.tokenId] != msg.sender) {
            revert("not staker");
        }
        (,, address token0, address token1,,,,,,,,) =
            MockPancakeNPM(nonfungiblePositionManager).positions(params.tokenId);
        amount0 = Math.min(owed0[params.tokenId], params.amount0Max);
        amount1 = Math.min(owed1[params.tokenId], params.amount1Max);
        owed0[params.tokenId] -= amount0;
        owed1[params.tokenId] -= amount1;
        if (amount0 != 0) {
            IERC20(token0).transfer(params.recipient, amount0);
        }
        if (amount1 != 0) {
            IERC20(token1).transfer(params.recipient, amount1);
        }
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != nonfungiblePositionManager) {
            revert("wrong nft");
        }
        (,, address token0, address token1, uint24 fee,,,,,,,) =
            MockPancakeNPM(nonfungiblePositionManager).positions(tokenId);
        if (
            v3PoolAddressPid[
                    MockPancakeFactory(MockPancakeNPM(nonfungiblePositionManager).factory())
                        .getPool(token0, token1, fee)
                ] == 0
        ) {
            revert("invalid nft");
        }
        staker[tokenId] = from;
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract PancakeStakingManagerUnitTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    address internal constant ALICE = address(0xA11CE);
    address internal constant RECIPIENT = address(0xBEEF);

    MockPancakeERC20 internal cake;
    MockPancakeERC20 internal tokenA;
    MockPancakeERC20 internal tokenB;
    MockPancakeERC20 internal weth;
    MockPancakeFactory internal factory;
    MockPancakePool internal positionPool;
    MockPancakePool internal cakeToken0Pool;
    MockPancakePool internal cakeToken1Pool;
    MockPancakeNPM internal npm;
    MockPancakeMasterChef internal masterChef;
    MockPancakeVault internal vault;
    PancakeStakingManager internal stakingManager;

    address internal positionToken0;
    address internal positionToken1;

    function setUp() external {
        cake = new MockPancakeERC20("CAKE", "CAKE");
        tokenA = new MockPancakeERC20("Token A", "TKNA");
        tokenB = new MockPancakeERC20("Token B", "TKNB");
        weth = new MockPancakeERC20("WETH", "WETH");

        factory = new MockPancakeFactory();
        positionPool = new MockPancakePool(address(tokenA), address(tokenB), 100);
        positionToken0 = positionPool.token0();
        positionToken1 = positionPool.token1();
        cakeToken0Pool = new MockPancakePool(address(cake), positionToken0, 500);
        cakeToken1Pool = new MockPancakePool(address(cake), positionToken1, 500);

        npm = new MockPancakeNPM(address(factory), address(weth));
        masterChef = new MockPancakeMasterChef(address(cake), address(npm));
        vault = new MockPancakeVault();

        factory.setPool(positionToken0, positionToken1, 100, address(positionPool));
        factory.setPool(address(cake), positionToken0, 500, address(cakeToken0Pool));
        factory.setPool(address(cake), positionToken1, 500, address(cakeToken1Pool));
        masterChef.addPool(1, IUniswapV3Pool(address(positionPool)));

        stakingManager = new PancakeStakingManager(
            INonfungiblePositionManager(address(npm)),
            IPancakeMasterChefV3(address(masterChef)),
            IERC20(address(cake)),
            IVault(address(vault)),
            address(0),
            address(0)
        );

        stakingManager.setGauge(address(positionPool), address(masterChef));
        stakingManager.setRewardBasePool(positionToken0, address(cakeToken0Pool));
        stakingManager.setRewardBasePool(positionToken1, address(cakeToken1Pool));

        npm.setPosition(TOKEN_ID, positionToken0, positionToken1, 100, -60, 60, 10);
        npm.mint(address(vault), TOKEN_ID);
        vault.setOwner(TOKEN_ID, ALICE);

        vm.prank(address(vault));
        npm.approve(address(stakingManager), TOKEN_ID);

        _fundPool(cakeToken0Pool);
        _fundPool(cakeToken1Pool);
        _fundPool(positionPool);
    }

    function testStakeRegistersManagerAsMasterChefUser() external {
        _stake();

        assertEq(stakingManager.tokenIdToGauge(TOKEN_ID), address(masterChef));
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(masterChef.staker(TOKEN_ID), address(stakingManager));
    }

    function testStakeOnlyVault() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        stakingManager.stakePosition(TOKEN_ID);
    }

    function testClaimRewardsToRecipient() external {
        _stake();
        cake.mint(address(masterChef), 10 ether);
        masterChef.setReward(TOKEN_ID, 10 ether);

        vm.prank(ALICE);
        uint256 claimed = stakingManager.claimRewards(TOKEN_ID, RECIPIENT);

        assertEq(claimed, 10 ether);
        assertEq(cake.balanceOf(RECIPIENT), 10 ether);
        assertEq(cake.balanceOf(address(stakingManager)), 0);
    }

    function testClaimRewardsRejectsUnauthorizedCaller() external {
        _stake();

        vm.prank(RECIPIENT);
        vm.expectRevert(Constants.Unauthorized.selector);
        stakingManager.claimRewards(TOKEN_ID, RECIPIENT);
    }

    function testUnstakeWithdrawsFromMasterChefAndForwardsCake() external {
        _stake();
        cake.mint(address(masterChef), 7 ether);
        masterChef.setReward(TOKEN_ID, 7 ether);

        vm.prank(address(vault));
        stakingManager.unstakePosition(TOKEN_ID);

        assertEq(stakingManager.tokenIdToGauge(TOKEN_ID), address(0));
        assertEq(npm.ownerOf(TOKEN_ID), address(vault));
        assertEq(cake.balanceOf(ALICE), 7 ether);
    }

    function testDecreaseLiquidityAndCollectKeepsNftStakedAndForwardsCake() external {
        _stake();
        cake.mint(address(masterChef), 3 ether);
        MockPancakeERC20(positionToken0).mint(address(masterChef), 11 ether);
        MockPancakeERC20(positionToken1).mint(address(masterChef), 13 ether);
        masterChef.setReward(TOKEN_ID, 3 ether);
        masterChef.setNextDecreaseLiquidityResult(11 ether, 13 ether);

        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1) = stakingManager.decreaseLiquidityAndCollect(
            TOKEN_ID, 4, 0, 0, 0, 0, block.timestamp + 1, RECIPIENT, ALICE
        );

        assertEq(amount0, 11 ether);
        assertEq(amount1, 13 ether);
        assertEq(IERC20(positionToken0).balanceOf(RECIPIENT), 11 ether);
        assertEq(IERC20(positionToken1).balanceOf(RECIPIENT), 13 ether);
        assertEq(cake.balanceOf(ALICE), 3 ether);
        assertEq(stakingManager.tokenIdToGauge(TOKEN_ID), address(masterChef));
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(masterChef.staker(TOKEN_ID), address(stakingManager));
    }

    function testCompoundRewardsKeepsNftStakedAndUsesMasterChefIncreaseLiquidity() external {
        _stake();
        cake.mint(address(masterChef), 100 ether);
        masterChef.setReward(TOKEN_ID, 100 ether);
        masterChef.setNextIncreaseLiquidityResult(30 ether, 40 ether);

        vm.prank(address(vault));
        (uint256 cakeAmount, uint256 amountAdded0, uint256 amountAdded1) =
            stakingManager.compoundRewards(TOKEN_ID, 0, 4_000, block.timestamp + 1);

        uint256 rewardX64 = stakingManager.totalRewardX64();
        uint256 q64 = 2 ** 64;
        uint256 rewardAmount0 = amountAdded0 * rewardX64 / q64;
        uint256 rewardAmount1 = amountAdded1 * rewardX64 / q64;

        assertEq(cakeAmount, 100 ether);
        assertEq(amountAdded0, 30 ether);
        assertEq(amountAdded1, 40 ether);
        assertEq(stakingManager.tokenIdToGauge(TOKEN_ID), address(masterChef));
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(masterChef.staker(TOKEN_ID), address(stakingManager));
        assertEq(IERC20(positionToken0).balanceOf(ALICE), 40 ether - amountAdded0 - rewardAmount0);
        assertEq(IERC20(positionToken1).balanceOf(ALICE), 60 ether - amountAdded1 - rewardAmount1);
        assertEq(IERC20(positionToken0).balanceOf(address(stakingManager)), rewardAmount0);
        assertEq(IERC20(positionToken1).balanceOf(address(stakingManager)), rewardAmount1);
    }

    function testCompoundRewardsRevertsWhenVaultReportsOpenDebt() external {
        _stake();
        vault.setDebtShares(TOKEN_ID, 1);

        vm.expectRevert(Constants.StakedPosition.selector);
        vm.prank(ALICE);
        stakingManager.compoundRewards(TOKEN_ID, 0, 5_000, block.timestamp + 1);
    }

    function testDecreaseLiquidityAndCollectRevertsWhenVaultReportsOpenDebt() external {
        _stake();
        vault.setDebtShares(TOKEN_ID, 1);

        vm.expectRevert(Constants.StakedPosition.selector);
        vm.prank(address(vault));
        stakingManager.decreaseLiquidityAndCollect(TOKEN_ID, 1, 0, 0, 0, 0, block.timestamp + 1, RECIPIENT, ALICE);
    }

    function testCompoundRewardsRevertsWhenRouteMissing() external {
        _stake();
        stakingManager.setRewardBasePool(positionToken0, address(0));
        stakingManager.setRewardBasePool(positionToken1, address(0));
        cake.mint(address(masterChef), 10 ether);
        masterChef.setReward(TOKEN_ID, 10 ether);

        vm.prank(address(vault));
        vm.expectRevert(Constants.NotConfigured.selector);
        stakingManager.compoundRewards(TOKEN_ID, 0, 5_000, block.timestamp + 1);
    }

    function testCompoundRewardsRevertsWhenPancakePoolOutputBelowValidatedMinimum() external {
        _stake();
        cakeToken0Pool.setOutputBps(9_700);
        cake.mint(address(masterChef), 10 ether);
        masterChef.setReward(TOKEN_ID, 10 ether);

        vm.prank(address(vault));
        vm.expectRevert(Constants.SlippageError.selector);
        stakingManager.compoundRewards(TOKEN_ID, 0, 10_000, block.timestamp + 1);
    }

    function testCompoundRewardsRevertsWhenPancakePoolFailsTwapCheck() external {
        _stake();
        cakeToken0Pool.setTick(500);
        cakeToken0Pool.setObservedTick(0);
        cake.mint(address(masterChef), 10 ether);
        masterChef.setReward(TOKEN_ID, 10 ether);

        vm.prank(address(vault));
        vm.expectRevert(Constants.TWAPCheckFailed.selector);
        stakingManager.compoundRewards(TOKEN_ID, 0, 10_000, block.timestamp + 1);
    }

    function _stake() internal {
        vm.prank(address(vault));
        stakingManager.stakePosition(TOKEN_ID);
    }

    function _fundPool(MockPancakePool pool) internal {
        MockPancakeERC20(pool.token0()).mint(address(pool), 1_000_000 ether);
        MockPancakeERC20(pool.token1()).mint(address(pool), 1_000_000 ether);
    }
}
