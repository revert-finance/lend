// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../../src/interfaces/pancake/IPancakeMasterChefV3.sol";
import "../../../src/interfaces/pancake/IPancakeMasterChefV3Staker.sol";
import "../../../src/interfaces/pancake/IPancakeV3SwapCallback.sol";

contract PancakeMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PancakeMockFactory {
    mapping(bytes32 => address) public pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
        pools[_key(tokenB, tokenA, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool) {
        pool = pools[_key(tokenA, tokenB, fee)];
    }

    function feeAmountTickSpacing(uint24 fee) external pure returns (int24 spacing) {
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        return 1;
    }

    function _key(address tokenA, address tokenB, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenA, tokenB, fee));
    }
}

contract PancakeMockPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public tick;
    uint160 public sqrtPriceX96 = 2 ** 96;
    uint256 public outputBps = 10_000;

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function setTick(int24 tick_) external {
        tick = tick_;
    }

    function setOutputBps(uint256 outputBps_) external {
        outputBps = outputBps_;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96_,
            int24 tick_,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (sqrtPriceX96, tick, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = int56(int24(tick)) * int56(uint56(secondsAgos[i]));
        }
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn = uint256(amountSpecified > 0 ? amountSpecified : -amountSpecified);
        uint256 amountOut = amountIn * outputBps / 10_000;

        if (zeroForOne) {
            IPancakeV3SwapCallback(msg.sender).pancakeV3SwapCallback(int256(amountIn), -int256(amountOut), data);
            PancakeMockERC20(token1).mint(recipient, amountOut);
            return (int256(amountIn), -int256(amountOut));
        }

        IPancakeV3SwapCallback(msg.sender).pancakeV3SwapCallback(-int256(amountOut), int256(amountIn), data);
        PancakeMockERC20(token0).mint(recipient, amountOut);
        return (-int256(amountOut), int256(amountIn));
    }
}

contract PancakeMockNPM is ERC721 {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable WETH9;
    uint256 public nextTokenId = 100;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => Position) public positionData;

    constructor(address factory_, address weth_) ERC721("Mock Pancake NPM", "MPNPM") {
        factory = factory_;
        WETH9 = weth_;
    }

    function mintPosition(
        address to,
        uint256 tokenId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 owed0,
        uint128 owed1
    ) external {
        _mint(to, tokenId);
        positionData[tokenId] = Position(token0, token1, fee, tickLower, tickUpper, liquidity, owed0, owed1);
    }

    function setFees(uint256 tokenId, uint128 owed0, uint128 owed1) external {
        positionData[tokenId].tokensOwed0 = owed0;
        positionData[tokenId].tokensOwed1 = owed1;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = positionData[tokenId];
        return (
            0,
            getApproved(tokenId),
            position.token0,
            position.token1,
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            0,
            0,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = nextTokenId++;
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        liquidity = uint128(amount0 + amount1);

        if (amount0 != 0) IERC20(params.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(params.token1).safeTransferFrom(msg.sender, address(this), amount1);

        _mint(params.recipient, tokenId);
        positionData[tokenId] =
            Position(params.token0, params.token1, params.fee, params.tickLower, params.tickUpper, liquidity, 0, 0);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(_isApprovedOrOwner(msg.sender, params.tokenId), "not approved");
        Position storage position = positionData[params.tokenId];
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Price slippage check");

        if (amount0 != 0) IERC20(position.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(position.token1).safeTransferFrom(msg.sender, address(this), amount1);

        liquidity = uint128(amount0 + amount1);
        position.liquidity += liquidity;
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        require(_isApprovedOrOwner(msg.sender, params.tokenId), "not approved");
        Position storage position = positionData[params.tokenId];
        require(params.liquidity <= position.liquidity, "too much liquidity");

        amount0 = params.liquidity;
        amount1 = params.liquidity;
        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Price slippage check");

        position.liquidity -= params.liquidity;
        position.tokensOwed0 += uint128(amount0);
        position.tokensOwed1 += uint128(amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        require(_isApprovedOrOwner(msg.sender, params.tokenId), "not approved");
        Position storage position = positionData[params.tokenId];
        amount0 = position.tokensOwed0;
        amount1 = position.tokensOwed1;
        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        if (amount0 != 0) PancakeMockERC20(position.token0).mint(params.recipient, amount0);
        if (amount1 != 0) PancakeMockERC20(position.token1).mint(params.recipient, amount1);
    }

    function burn(uint256 tokenId) external payable {
        require(_isApprovedOrOwner(msg.sender, tokenId), "not approved");
        require(positionData[tokenId].liquidity == 0, "liquidity");
        _burn(tokenId);
        delete positionData[tokenId];
    }
}

contract PancakeMockMasterChef is IERC721Receiver, IPancakeMasterChefV3 {
    using SafeERC20 for IERC20;

    address public immutable override CAKE;
    address public immutable override nonfungiblePositionManager;

    mapping(uint256 => address) public positionUser;
    mapping(uint256 => uint256) public rewards;

    constructor(address cake_, address npm_) {
        CAKE = cake_;
        nonfungiblePositionManager = npm_;
    }

    function setReward(uint256 tokenId, uint256 reward) external {
        rewards[tokenId] = reward;
    }

    function v3PoolAddressPid(address) external pure returns (uint256 pid) {
        return 1;
    }

    function poolInfo(uint256)
        external
        pure
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
        return (0, IUniswapV3Pool(address(0)), address(0), address(0), 0, 0, 0);
    }

    function pendingCake(uint256 tokenId) external view returns (uint256 reward) {
        reward = rewards[tokenId];
    }

    function harvest(uint256 tokenId, address to) external returns (uint256 reward) {
        _requireUser(tokenId);
        reward = rewards[tokenId];
        rewards[tokenId] = 0;
        if (reward != 0) PancakeMockERC20(CAKE).mint(to, reward);
    }

    function withdraw(uint256 tokenId, address to) external returns (uint256 reward) {
        _requireUser(tokenId);
        delete positionUser[tokenId];
        reward = rewards[tokenId];
        rewards[tokenId] = 0;
        if (reward != 0) PancakeMockERC20(CAKE).mint(to, reward);
        IERC721(nonfungiblePositionManager).safeTransferFrom(address(this), to, tokenId);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        _requireUser(params.tokenId);
        return INonfungiblePositionManager(nonfungiblePositionManager).collect(params);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        _requireUser(params.tokenId);
        return INonfungiblePositionManager(nonfungiblePositionManager).increaseLiquidity(params);
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == nonfungiblePositionManager, "wrong nft");
        positionUser[tokenId] = from;
        return IERC721Receiver.onERC721Received.selector;
    }

    function _requireUser(uint256 tokenId) internal view {
        require(positionUser[tokenId] == msg.sender, "not MasterChef user");
    }
}

    contract PancakeNoopTransformer {
        function execute(uint256) external {}
    }

    contract PancakeRewardTransformer is IPancakeMasterChefV3RewardTransformer {
        IERC20 public immutable cake;
        uint256 public lastCakeAmount;
        address public lastOwner;

        constructor(IERC20 cake_) {
            cake = cake_;
        }

        function executeWithReward(uint256, address owner, uint256 cakeAmount, bytes calldata) external {
            lastCakeAmount = cakeAmount;
            lastOwner = owner;
            if (cakeAmount != 0) {
                SafeERC20.safeTransfer(cake, owner, cakeAmount);
            }
        }
    }

    contract PancakeReplaceTransformer {
        INonfungiblePositionManager public immutable npm;

        constructor(INonfungiblePositionManager npm_) {
            npm = npm_;
        }

        function replace(uint256 oldTokenId, uint256 newTokenId, uint128 liquidity, uint256 deadline) external {
            if (liquidity != 0) {
                npm.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(oldTokenId, liquidity, 0, 0, deadline)
                );
                npm.collect(
                    INonfungiblePositionManager.CollectParams(
                        oldTokenId, address(this), type(uint128).max, type(uint128).max
                    )
                );
            }
            npm.safeTransferFrom(address(this), msg.sender, newTokenId);
        }
    }
