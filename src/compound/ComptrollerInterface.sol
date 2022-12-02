// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "../modules/ICollateralModule.sol";

abstract contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    function getCollateralModule() virtual external view returns(ICollateralModule);

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata cTokens) virtual external returns (uint[] memory);
    function exitMarket(address cToken) virtual external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address cToken, address minter, uint mintAmount) virtual external returns (uint);
    function mintVerify(address cToken, address minter, uint mintAmount, uint mintTokens) virtual external;

    function redeemAllowed(address cToken, address redeemer, uint redeemTokens) virtual external returns (uint);
    function redeemVerify(address cToken, address redeemer, uint redeemAmount, uint redeemTokens) virtual external;

    function borrowAllowed(address cToken, address borrower, uint borrowAmount) virtual external returns (uint);
    function borrowVerify(address cToken, address borrower, uint borrowAmount) virtual external;

    function repayBorrowAllowed(
        address cToken,
        address payer,
        address borrower,
        uint repayAmount) virtual external returns (uint);
    function repayBorrowVerify(
        address cToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) virtual external;

    function liquidateBorrowAllowed(
        address cTokenBorrowed,
        address cTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) virtual external returns (uint);

    function liquidateBorrowAllowedUniV3(
        address cTokenBorrowed,
        uint256 collateralTokenId,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) virtual external returns (uint256);

    function liquidateBorrowVerify(
        address cTokenBorrowed,
        address cTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) virtual external;

    function seizeAllowed(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) virtual external returns (uint);

    function seizeAllowedUniV3(
        address module,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 tokenId,
        uint256 seizeLiquidity,
        uint256 seizeFeesToken0,
        uint256 seizeFeesToken1,
        uint256 seizeCToken0,
        uint256 seizeCToken1
    ) virtual external returns (uint256);

    function seizeVerify(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) virtual external;

    function transferAllowed(address cToken, address src, address dst, uint transferTokens) virtual external returns (uint);
    function transferVerify(address cToken, address src, address dst, uint transferTokens) virtual external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint repayAmount) virtual external view returns (uint, uint);

    function liquidateCalculateSeizeTokensUniV3(
        address cTokenBorrowed,
        uint collateralTokenId,
        uint repayAmount) virtual external view returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        );
}
