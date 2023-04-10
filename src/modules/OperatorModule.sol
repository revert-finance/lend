// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Module.sol";

abstract contract OperatorModule is Module {

    // admin events
    event OperatorChanged(address newOperator);
    event TWAPConfigChanged(uint32 TWAPSeconds, uint16 maxTWAPTickDifference);
    event SwapRouterChanged(address newSwapRouter);

    // configurable by owner
    address public operator;
    uint32 public TWAPSeconds;
    uint16 public maxTWAPTickDifference;
    address public swapRouter;

    constructor(INonfungiblePositionManager _npm, address _swapRouter, address _operator, uint32 _TWAPSeconds, uint16 _maxTWAPTickDifference) Module(_npm) {
         swapRouter = _swapRouter;
        emit SwapRouterChanged(_swapRouter);

        operator = _operator;
        emit OperatorChanged(_operator);

        if (_maxTWAPTickDifference > uint16(type(int16).max) || _TWAPSeconds == 0) {
            revert InvalidConfig();
        }
        TWAPSeconds = _TWAPSeconds;
        maxTWAPTickDifference = _maxTWAPTickDifference;
        emit TWAPConfigChanged(_TWAPSeconds, _maxTWAPTickDifference);
    }

     /**
     * @notice Owner controlled function to change swap router (onlyOwner)
     * @param _swapRouter new swap router
     */
    function setSwapRouter(address _swapRouter) external onlyOwner {
        emit SwapRouterChanged(_swapRouter);
        swapRouter = _swapRouter;
    }

    /**
     * @notice Owner controlled function to change operator address
     * @param _operator new operator
     */
    function setOperator(address _operator) external onlyOwner {
        emit OperatorChanged(_operator);
        operator = _operator;
    }

    /**
     * @notice Owner controlled function to increase TWAPSeconds / decrease maxTWAPTickDifference
     */
    function setTWAPConfig(uint16 _maxTWAPTickDifference, uint32 _TWAPSeconds) external onlyOwner {
        if (_TWAPSeconds < TWAPSeconds) {
            revert InvalidConfig();
        }
        if (_maxTWAPTickDifference > maxTWAPTickDifference) {
            revert InvalidConfig();
        }
        emit TWAPConfigChanged(_TWAPSeconds, _maxTWAPTickDifference);
        TWAPSeconds = _TWAPSeconds;
        maxTWAPTickDifference = _maxTWAPTickDifference;
    }
}