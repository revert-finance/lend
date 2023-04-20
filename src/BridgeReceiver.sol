
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./V3Utils.sol";

interface ILayerZeroReceiver {
    // @notice LayerZero endpoint will invoke this function to deliver the message on the destination
    // @param _srcChainId - the source endpoint identifier
    // @param _srcAddress - the source sending contract address from the source chain
    // @param _nonce - the ordered message nonce
    // @param _payload - the signed payload is the UA bytes has encoded to be sent
    function lzReceive(uint16 _srcChainId, bytes calldata _srcAddress, uint64 _nonce, bytes calldata _payload) external;
}

contract BridgeReceiver is ILayerZeroReceiver, Ownable {

    // TODO updatable values by owner?
    address public immutable lzEndpoint;
    V3Utils public immutable v3Utils;

    struct PositionInfo {

        address owner;

        IERC20 token0;
        IERC20 token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;

        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
    }

    mapping(uint256 => PositionInfo) positions;

    error NotLayerZero();
    error NotOwner();

    constructor(address _lzEndpoint, V3Utils _v3Utils) {
        lzEndpoint = _lzEndpoint;
        v3Utils = _v3Utils;
    }

    // override from ILayerZeroReceiver
    function lzReceive(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload) override external {
        if (msg.sender != address(lzEndpoint)) {
            revert NotLayerZero();
        }
        address fromAddress;
        assembly {
            fromAddress := mload(add(_srcAddress, 20))
        }
        
        // TODO extract info from payload
        uint tokenId;
        uint amount0;
        uint amount1;
        IERC20 token0;
        IERC20 token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;

        // register deposit - if there is another deposit for same tokenid - add amounts
        PositionInfo storage info = positions[tokenId];
        if (info.owner == address(0)) {
            info.owner = fromAddress;
            info.token0 = token0;
            info.token1 = token1;
            info.fee = fee;
            info.tickLower = tickLower;
            info.tickUpper = tickUpper;
        } else if (info.owner != fromAddress && info.amount0 == 0 && info.amount1 == 0) {
            // if owner changed on sourcechain update ONLY if there are no amounts left
            info.owner = fromAddress;
        }
        info.amount0 += amount0;
        info.amount1 += amount1;
    }

    struct CreatePositionParams {
        uint256 tokenId;
        uint256 deadline;

        bool swap0For1;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
    }

    // recreates position from provided tokens - callable by revert - takes fees for protocol
    function createPosition(CreatePositionParams calldata params) external onlyOwner returns (uint256 newTokenId) {

        PositionInfo storage info = positions[params.tokenId];

        uint amount0 = info.amount0;
        uint amount1 = info.amount1;

        // use full amount
        info.amount0 = 0;
        info.amount1 = 0;

        info.token0.approve(address(v3Utils), amount0);
        info.token1.approve(address(v3Utils), amount1);

        bytes memory eb;

        // mint to owner 
        v3Utils.swapAndMint(V3Utils.SwapAndMintParams(
            info.token0, 
            info.token1, 
            info.fee, 
            info.tickLower, 
            info.tickUpper, 
            amount0, 
            amount1, 
            info.owner, 
            info.owner, 
            params.deadline, 
            params.swap0For1 ? info.token0 : info.token1, 
            params.swap0For1 ? 0 : params.amountIn,
            params.swap0For1 ? 0 : params.amountOutMin,
            params.swap0For1 ? eb : params.swapData,
            params.swap0For1 ? params.amountIn : 0,
            params.swap0For1 ? params.amountOutMin : 0,
            params.swap0For1 ? params.swapData : eb,
            0,
            0,
            false,
            eb));
    }


    // claims available amounts instead of creating position - can be done as soon as enough tokens are available
    function claim(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {

        PositionInfo storage info = positions[tokenId];

        address owner = info.owner;
        if(msg.sender != info.owner) {
            revert NotOwner();
        }

        amount0 = info.amount0;
        amount1 = info.amount1;

        info.amount0 = 0;
        info.amount1 = 0;

        if (amount0 > 0) {
            SafeERC20.safeTransfer(info.token0, owner, amount0);
        }
        if (amount1 > 0) {
            SafeERC20.safeTransfer(info.token1, owner, amount1);
        }
    }
}