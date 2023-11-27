// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVault {

    function asset() external returns (address);
    function ownerOf(uint tokenId) external returns (address);

    // params for creation of loan
    struct CreateParams {
        // owner of the loan
        address owner;
        // initial borrow amount
        uint amount;
        // initial transformer
        address transformer;
        // initial transformer data
        bytes transformerData;
    }

    function create(uint256 tokenId, CreateParams calldata params) external;
    function createWithPermit(uint256 tokenId, CreateParams calldata params, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;

    function approveTransform(address target, bool active) external;
    function transform(uint tokenId, address transformer, bytes calldata data) external returns (uint);

    // params for decreasing liquidity of collateralized position
    struct DecreaseLiquidityAndCollectParams {
        uint256 tokenId;
        uint128 liquidity;

        // min amount to accept from liquidity removal
        uint256 amount0Min;
        uint256 amount1Min;

        // amount to remove from fees additional to the liquidity amounts
        uint128 feeAmount0; // (if uint256(128).max - all fees)
        uint128 feeAmount1; // (if uint256(128).max - all fees)

        uint256 deadline;
        address recipient;
    }

    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params) external returns (uint256 amount0, uint256 amount1);

    function borrow(uint tokenId, uint amount) external;
    function repay(uint tokenId, uint amount, bool isShare) external;

    function liquidate(uint tokenId) external;
}