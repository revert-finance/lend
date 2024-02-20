// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IErrors {
    error Unauthorized();
    error Reentrancy();
    error NotConfigured();
    error NotReady();
    error InvalidConfig();
    error TWAPCheckFailed();
    error WrongContract();

    error SwapFailed();
    error SlippageError();
    error MissingSwapData();
    error SwapAmountTooLarge();

    error LiquidityChanged();
    error ExceedsMaxReward();
    error InvalidPool();
    error ChainlinkPriceError();
    error PriceDifferenceExceeded();

    error CollateralFail();
    error MinLoanSize();
    error GlobalDebtLimit();
    error GlobalLendLimit();
    error DailyDebtIncreaseLimit();
    error DailyLendIncreaseLimit();
    error InsufficientLiquidity();
    error NotLiquidatable();
    error InterestNotUpdated();
    error RepayExceedsDebt();
    error TransformNotAllowed();
    error TransformFailed();
    error CollateralFactorExceedsMax();
    error CollateralValueLimit();
    error NoLiquidity();
    error DebtChanged();

    error SelfSend();
    error NotSupportedWhatToDo();
    error SameToken();
    error AmountError();
    error CollectError();
    error TransferError();

    error TooMuchEtherSent();
    error NoEtherToken();
    error EtherSendFailed();
    error NotWETH();

    error NotEnoughReward();
    error SameRange();
    error NotSupportedFeeTier();
}
