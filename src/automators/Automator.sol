// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../lib/IWETH9.sol";
import "../utils/Swapper.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IProtocolFeeController.sol";

abstract contract Automator is Ownable2Step, Swapper, IProtocolFeeController {
    uint32 public constant MIN_TWAP_SECONDS = 60; // 1 minute
    uint32 public constant MAX_TWAP_TICK_DIFFERENCE = 200; // 2%

    // admin events
    event OperatorChanged(address newOperator, bool active);
    event TWAPConfigChanged(uint32 TWAPSeconds, uint16 maxTWAPTickDifference);

    // configurable by owner
    mapping(address => bool) public operators;

    address public override withdrawer;
    uint32 public TWAPSeconds;
    uint16 public maxTWAPTickDifference;

    error ZeroAddress();

    constructor(
        INonfungiblePositionManager npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Swapper(npm, _universalRouter, _zeroxAllowanceHolder) {
        setOperator(_operator, true);
        setWithdrawer(_withdrawer);
        setTWAPConfig(_maxTWAPTickDifference, _TWAPSeconds);
    }

    /**
     * @notice Owner controlled function to set withdrawer address
     * @param _withdrawer withdrawer
     */
    function setWithdrawer(address _withdrawer) public virtual override onlyOwner {
        if (_withdrawer == address(0)) {
            revert InvalidConfig();
        }
        emit WithdrawerChanged(_withdrawer);
        withdrawer = _withdrawer;
    }

    /**
     * @notice Owner controlled function to activate/deactivate operator address
     * @param _operator operator
     * @param _active active or not
     */
    function setOperator(address _operator, bool _active) public onlyOwner {
        emit OperatorChanged(_operator, _active);
        operators[_operator] = _active;
    }

    /**
     * @notice Owner controlled function to increase TWAPSeconds / decrease maxTWAPTickDifference
     */
    function setTWAPConfig(uint16 _maxTWAPTickDifference, uint32 _TWAPSeconds) public onlyOwner {
        if (_TWAPSeconds < MIN_TWAP_SECONDS) {
            revert InvalidConfig();
        }
        if (_maxTWAPTickDifference > MAX_TWAP_TICK_DIFFERENCE) {
            revert InvalidConfig();
        }
        emit TWAPConfigChanged(_TWAPSeconds, _maxTWAPTickDifference);
        TWAPSeconds = _TWAPSeconds;
        maxTWAPTickDifference = _maxTWAPTickDifference;
    }

    /**
     * @notice Withdraws token balance (accumulated protocol fee)
     * @param tokens Addresses of tokens to withdraw
     * @param to Address to send to
     */
    function withdrawBalances(address[] calldata tokens, address to) external virtual override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        address token;
        uint256 balance;
        for (; i < count; ++i) {
            token = tokens[i];
            balance = IERC20(token).balanceOf(address(this));
            if (balance != 0) {
                _transferToken(to, IERC20(token), balance, true);
            }
        }
    }

    /**
     * @notice Withdraws ETH balance
     * @param to Address to send to
     */
    function withdrawETH(address to) external override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 balance = address(this).balance;
        if (balance != 0) {
            (bool sent,) = to.call{value: balance}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        }
    }

    function _decreaseFullLiquidityAndCollect(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amountRemoveMin0,
        uint256 amountRemoveMin1,
        uint256 deadline
    ) internal returns (uint256 amount0, uint256 amount1, uint256 feeAmount0, uint256 feeAmount1) {
        if (liquidity != 0) {
            // store in temporarely "misnamed" variables - see comment below
            (feeAmount0, feeAmount1) = nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(
                    tokenId, liquidity, amountRemoveMin0, amountRemoveMin1, deadline
                )
            );
        }
        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)
        );

        // fee amount is what was collected additionally to liquidity amount
        feeAmount0 = amount0 - feeAmount0;
        feeAmount1 = amount1 - feeAmount1;
    }

    // transfers token (or unwraps WETH and sends ETH)
    function _transferToken(address to, IERC20 token, uint256 amount, bool unwrap) internal {
        if (unwrap && address(weth) == address(token)) {
            weth.withdraw(amount);
            (bool sent,) = to.call{value: amount}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        } else {
            SafeERC20.safeTransfer(token, to, amount);
        }
    }

    // needed for WETH unwrapping
    receive() external payable {
        if (msg.sender != address(weth)) {
            revert NotWETH();
        }
    }
}
