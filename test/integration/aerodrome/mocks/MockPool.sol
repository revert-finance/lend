// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Pool.sol";

contract MockPool is IUniswapV3Pool {
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public immutable override tickSpacing;
    uint128 public immutable override maxLiquidityPerTick;
    
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint16 public observationIndex;
    uint16 public observationCardinality;
    uint16 public observationCardinalityNext;
    uint8 public feeProtocol;
    bool public unlocked = true;
    
    uint128 public override liquidity;
    uint256 public override feeGrowthGlobal0X128;
    uint256 public override feeGrowthGlobal1X128;
    
    constructor(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        maxLiquidityPerTick = type(uint128).max;
        sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price
        tick = 0;
    }
    
    function slot0() external view override returns (
        uint160 sqrtPriceX96_,
        int24 tick_,
        uint16 observationIndex_,
        uint16 observationCardinality_,
        uint16 observationCardinalityNext_,
        uint8 feeProtocol_,
        bool unlocked_
    ) {
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
    
    function setSqrtPriceX96(uint160 _sqrtPriceX96) external {
        sqrtPriceX96 = _sqrtPriceX96;
    }
    
    function setTick(int24 _tick) external {
        tick = _tick;
    }
    
    // Implement required but unused functions
    function factory() external view override returns (address) {
        return address(0);
    }
    
    function protocolFees() external view override returns (uint128, uint128) {
        return (0, 0);
    }
    
    function observe(uint32[] calldata secondsAgos) external view override returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        
        // Return mock values for TWAP calculation
        for (uint i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = tick * int56(uint56(secondsAgos[i]));
            secondsPerLiquidityCumulativeX128s[i] = uint160(secondsAgos[i]) << 128;
        }
    }
    
    function observations(uint256) external pure override returns (uint32, int56, uint160, bool) {
        revert("Not implemented");
    }
    
    function tickBitmap(int16) external pure override returns (uint256) {
        return 0;
    }
    
    function ticks(int24) external pure override returns (
        uint128 liquidityGross, 
        int128 liquidityNet, 
        uint256 feeGrowthOutside0X128, 
        uint256 feeGrowthOutside1X128, 
        int56 tickCumulativeOutside, 
        uint160 secondsPerLiquidityOutsideX128, 
        uint32 secondsOutside, 
        bool initialized
    ) {
        // Return zeros for all values
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
    
    function positions(bytes32) external pure override returns (
        uint128 _liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) {
        // Return zeros for all values
        return (0, 0, 0, 0, 0);
    }
    
    function mint(address, int24, int24, uint128, bytes calldata) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }
    
    function collect(address, int24, int24, uint128, uint128) external pure override returns (uint128, uint128) {
        revert("Not implemented");
    }
    
    function burn(int24, int24, uint128) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }
    
    function swap(address, bool, int256, uint160, bytes calldata) external pure override returns (int256, int256) {
        revert("Not implemented");
    }
    
    function flash(address, uint256, uint256, bytes calldata) external pure override {
        revert("Not implemented");
    }
    
    function increaseObservationCardinalityNext(uint16) external pure override {
        revert("Not implemented");
    }
    
    function initialize(uint160) external pure override {
        revert("Not implemented");
    }
    
    function collectProtocol(address, uint128, uint128) external pure override returns (uint128, uint128) {
        revert("Not implemented");
    }
    
    function setFeeProtocol(uint8 feeProtocol0_, uint8 feeProtocol1_) external override {
        feeProtocol = (feeProtocol1_ << 4) | feeProtocol0_;
    }
    
    function snapshotCumulativesInside(int24, int24) external pure override returns (
        int56 tickCumulativeInside,
        uint160 secondsPerLiquidityInsideX128,
        uint32 secondsInside
    ) {
        return (0, 0, 0);
    }
}