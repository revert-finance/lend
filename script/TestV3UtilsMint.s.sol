// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/IV3Utils.sol";

interface IV3UtilsWithParams {
    struct SwapAndMintParams {
        IERC20 token0;
        IERC20 token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        address recipient;
        address recipientNFT;
        uint256 deadline;
        IERC20 swapSourceToken;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        bytes returnData;
        bytes permitData;
    }

    function swapAndMint(SwapAndMintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

contract TestV3UtilsMint is Script {
    IV3UtilsWithParams constant v3Utils = IV3UtilsWithParams(0x995407CAF4C1D491Da073b09bF9471d70C50727C);
    IERC20 constant WETH = IERC20(0x4200000000000000000000000000000000000006);
    IERC20 constant OP = IERC20(0x4200000000000000000000000000000000000042);

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        
        // Check balances first
        uint256 wethBalance = WETH.balanceOf(owner);
        uint256 opBalance = OP.balanceOf(owner);
        console.log("WETH Balance:", wethBalance);
        console.log("OP Balance:", opBalance);
        console.log("Owner:", owner);
        
        vm.startBroadcast();

        // Approve exact amounts to V3Utils
        WETH.approve(address(v3Utils), 1000000000000000);
        OP.approve(address(v3Utils), 1196402544761785660);

        console.log("Approvals done, attempting mint through V3Utils...");

        IV3UtilsWithParams.SwapAndMintParams memory params = IV3UtilsWithParams.SwapAndMintParams({
            token0: WETH,
            token1: OP,
            fee: 200,  // tickSpacing
            tickLower: 73000,
            tickUpper: 73800,
            amount0: 1000000000000000,    // Same WETH amount
            amount1: 1196402544761785660, // Same OP amount
            recipient: owner,             // Leftover tokens go here
            recipientNFT: owner,          // NFT goes here
            deadline: block.timestamp + 3600,
            swapSourceToken: IERC20(address(0)), // No swap source token
            amountIn0: 0,                // No swap needed
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,                // No swap needed
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 0,            // No minimum amounts
            amountAddMin1: 0,
            returnData: "",              // No return data needed
            permitData: ""               // No permit data needed
        });

        try v3Utils.swapAndMint(params) returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) {
            console.log("Mint through V3Utils successful!");
            console.log("Token ID:", tokenId);
            console.log("Liquidity:", liquidity);
            console.log("WETH used:", amount0);
            console.log("OP used:", amount1);
        } catch Error(string memory reason) {
            console.log("Mint failed with reason:", reason);
        } catch Panic(uint256 code) {
            console.log("Mint failed with panic code:", code);
        } catch (bytes memory lowLevelData) {
            console.log("Mint failed with low-level data:");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();
    }
} 