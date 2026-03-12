// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../../../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";

contract MockAerodromeFactory is IAerodromeSlipstreamFactory {
    mapping(address => mapping(address => mapping(int24 => address))) public pools;
    mapping(int24 => uint24) private tickSpacingByAmount;
    address public immutable owner;
    address public immutable poolImplementation;

    constructor() {
        owner = msg.sender;
        poolImplementation = address(0x1234); // Mock implementation
    }

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pools[token0][token1][tickSpacing] = pool;
        tickSpacingByAmount[tickSpacing] = _toUint24(tickSpacing);
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view override returns (address pool) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[token0][token1][tickSpacing];
    }

    function feeAmountTickSpacing(int24 tickSpacing) external view returns (int24) {
        return _toInt24(tickSpacingByAmount[tickSpacing]);
    }

    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160)
        external
        returns (address pool)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        // Create a simple mock pool address
        pool = address(uint160(uint256(keccak256(abi.encodePacked(token0, token1, tickSpacing)))));
        pools[token0][token1][tickSpacing] = pool;
        return pool;
    }

    function _toUint24(int24 value) internal pure returns (uint24 result) {
        assembly ("memory-safe") {
            result := value
        }
    }

    function _toInt24(uint24 value) internal pure returns (int24 result) {
        assembly ("memory-safe") {
            result := value
        }
    }
}
