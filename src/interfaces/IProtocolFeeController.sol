// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IProtocolFeeController {
    event WithdrawerChanged(address newWithdrawer);

    function withdrawer() external view returns (address);
    function setWithdrawer(address _withdrawer) external;
    function withdrawBalances(address[] calldata tokens, address to) external;
    function withdrawETH(address to) external;
}
