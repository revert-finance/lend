// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

abstract contract Constants {
    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q128 = 2 ** 128;
    uint256 internal constant Q160 = 2 ** 160;

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

    error ExceedsMaxReward();
    error InvalidPool();
    error InsufficientLiquidity();
    error TransformNotAllowed();
    error TransformFailed();
    error NoLiquidity();

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
