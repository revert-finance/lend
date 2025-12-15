// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ISugar
/// @notice Interface for Aerodrome Sugar v3 contract (LP data aggregator) - 32-field version
/// @dev Sugar contract on Base: 0x9DE6Eab7a910A288dE83a04b6A43B52Fd1246f1E
/// @dev Struct must match exact field order from Vyper contract for ABI decoding
interface ISugar {
    struct Lp {
        address lp;                  // Pool address
        string symbol;               // Pool symbol (e.g., "WETH-USDC")
        uint8 decimals;              // Pool decimals
        uint256 liquidity;           // Total liquidity

        // CL pool specific fields
        int24 type_;                 // Pool type: 0=V2 stable, 1=V2 volatile, >1=CL with tick spacing
        int24 tick;                  // Current tick (for CL pools)
        uint160 sqrt_ratio;          // Current sqrt price ratio (for CL pools)

        // Token0 data
        address token0;              // Token0 address
        uint256 reserve0;            // Reserve of token0
        uint256 staked0;             // Staked amount of token0

        // Token1 data
        address token1;              // Token1 address
        uint256 reserve1;            // Reserve of token1
        uint256 staked1;             // Staked amount of token1

        // Gauge data
        address gauge;               // Gauge contract address
        uint256 gauge_liquidity;     // Liquidity in gauge
        bool gauge_alive;            // Whether gauge is active

        // Protocol addresses
        address fee;                 // Fee contract address
        address bribe;               // Bribe contract address
        address factory;             // Factory address

        // Emissions data
        uint256 emissions;           // Emissions amount (per second)
        address emissions_token;     // Emissions token address
        uint256 emissions_cap;       // Emissions cap measured in bps
        uint256 pool_fee;            // Pool swap fee (percentage)
        uint256 unstaked_fee;        // Unstaked fee percentage on CL pools
        uint256 token0_fees;         // Accumulated token0 fees
        uint256 token1_fees;         // Accumulated token1 fees

        // Pool metadata
        uint256 locked;              // Pool total locked liquidity amount
        uint256 emerging;            // Indicates if the pool is emerging
        uint32 created_at;           // Pool creation timestamp
        address nfpm;                // NFT Position Manager (for CL pools)
        address alm;                 // Automated Liquidity Manager
        address root;                // Root/base address
    }

    /// @notice Get all pools with pagination
    /// @param _limit Maximum number of pools to return
    /// @param _offset Starting index for pagination
    /// @param _filter Filter parameter (use 0 for no filter)
    /// @return Array of Lp structs containing pool data
    function all(uint256 _limit, uint256 _offset, uint256 _filter) external view returns (Lp[] memory);

    /// @notice Get pool data by index
    /// @param _index Pool index
    /// @return Lp struct for the pool
    function byIndex(uint256 _index) external view returns (Lp memory);
}
