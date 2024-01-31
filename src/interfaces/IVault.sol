// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IVault is IERC4626 {

    function vaultInfo() external view returns (uint debt, uint lent, uint balance, uint available, uint reserves, uint debtExchangeRateX96, uint lendExchangeRateX96);
    function lendInfo(address account) external view returns (uint amount);
    function loanInfo(uint tokenId) external view returns (uint debt, uint fullValue, uint collateralValue, uint liquidationCost, uint liquidationValue);

    function ownerOf(uint tokenId) external returns (address);

    // functions for iterating over owners loans
    function loanCount(address owner) external view returns (uint);
    function loanAtIndex(address owner, uint index) external view returns (uint);

    function create(uint256 tokenId, address recipient) external;
    function createWithPermit(uint256 tokenId, address owner, address recipient, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;

    function approveTransform(uint256 tokenId, address target, bool active) external;
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

    struct LiquidateParams {
        // token to liquidate
        uint256 tokenId;
        
        // expected debt shares - reverts if changed in the meantime
        uint256 debtShares;

        // min amount to recieve
        uint256 amount0Min;
        uint256 amount1Min;

        // recipient of rewarded tokens
        address recipient;
    }

    function liquidate(LiquidateParams calldata params) external returns (uint256 amount0, uint256 amount1);
}