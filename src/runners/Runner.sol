// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../V3Utils.sol";

abstract contract Runner is Ownable {

    uint256 internal constant Q64 = 2 ** 64;
    uint256 internal constant Q96 = 2 ** 96;

    error NotSupportedFeeTier();
    error OraclePriceCheckFailed();
    error InvalidConfig();
    error EtherSendFailed();
    error NotWETH();

    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event TWAPConfigChanged(uint32 TWAPSeconds, uint16 maxTWAPTickDifference);

    event FeePaid(address token, uint256 amount, address to);

    // TODO v3utils updateable?
    V3Utils public immutable v3Utils;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;
    IWETH9 immutable public weth;

    // configurable by owner
    address public operator;
    uint32 public TWAPSeconds;
    uint16 public maxTWAPTickDifference;

    // init with all needed values
    constructor(V3Utils _v3Utils, address _operator, uint32 _TWAPSeconds, uint16 _maxTWAPTickDifference) {
        v3Utils = _v3Utils;
        INonfungiblePositionManager npm = _v3Utils.nonfungiblePositionManager();
        nonfungiblePositionManager = npm;
        weth = IWETH9(npm.WETH9());
        factory = IUniswapV3Factory(npm.factory());
        operator = _operator;
        emit OperatorChanged(address(0), _operator);
        if (_maxTWAPTickDifference > uint16(type(int16).max) || _TWAPSeconds == 0) {
            revert InvalidConfig();
        }
        TWAPSeconds = _TWAPSeconds;
        maxTWAPTickDifference = _maxTWAPTickDifference;
        emit TWAPConfigChanged(_TWAPSeconds, _maxTWAPTickDifference);
    }

    /**
     * @notice Owner controlled function to change operator address
     */
    function setOperator(address _operator) external onlyOwner {
        emit OperatorChanged(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Owner controlled function to increase TWAPSeconds / decrease maxTWAPTickDifference
     */
    function setTWAPConfig(uint32 _TWAPSeconds, uint16 _maxTWAPTickDifference) external onlyOwner {
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

    function _doTWAPPriceCheck(IUniswapV3Pool pool, int24 currentTick, uint32 TWAPSeconds, uint16 maxTWAPTickDifference) internal {
         // get pool twap tick - if not enough history available this breaks
        int24 twapTick = _getTWAPTick(pool, TWAPSeconds);

        // checks if out of valid range - revert
        // this allows us to use current price and no remove / add slippage checks later on
        if (twapTick - currentTick < -int16(maxTWAPTickDifference) || twapTick - currentTick > int16(maxTWAPTickDifference)) {
            revert OraclePriceCheckFailed();
        }
    }

    function _getTWAPTick(IUniswapV3Pool pool, uint32 twapPeriod) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0; // from (before)
        secondsAgos[1] = twapPeriod; // from (before)

        // pool observe may fail when there is not enough history available
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        return int24((tickCumulatives[0] - tickCumulatives[1]) / int56(uint56(twapPeriod)));
    }

    // get pool for token
    function _getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal view returns (IUniswapV3Pool) {
        return
            IUniswapV3Pool(
                PoolAddress.computeAddress(
                    address(factory),
                    PoolAddress.getPoolKey(tokenA, tokenB, fee)
                )
            );
    }

    function _getMinAmountOut(uint256 amountIn, uint256 priceX96, uint64 maxSlippageX64, bool swap0To1) internal returns (uint256) {
        return FullMath.mulDiv(
                Q64 - maxSlippageX64,
                swap0To1
                    ? FullMath.mulDiv(amountIn, priceX96, Q96)
                    : FullMath.mulDiv(amountIn, Q96, priceX96),
                Q64
            );
    }

    // calculate max available fee and sends requested fee to operator, returns remaining tokens after transfer
    function _removeAndSendFeeToOperator(bool takeFeeFrom0, address feeToken, uint256 amount0, uint256 amount1, uint256 priceX96, uint256 feeAmount, uint64 maxGasFeeRewardX64) internal returns (uint, uint) {
        // max fee in feeToken
        uint256 totalFeeTokenAmount = takeFeeFrom0 ? amount0 + FullMath.mulDiv(amount1, Q96, priceX96) : amount1 + FullMath.mulDiv(amount0, priceX96, Q96);

        // calculate max permited fee amount for this position
        uint256 maxFeeAmount = FullMath.mulDiv(totalFeeTokenAmount, maxGasFeeRewardX64, Q64);

        // calculate fee amount which can be sent.. it can be less.. so it is the operators responsibility to do correct swap
        uint256 effectiveFeeAmount = feeAmount > (takeFeeFrom0 ? amount0 : amount1) ? (takeFeeFrom0 ? amount0 : amount1) : feeAmount;
        if (effectiveFeeAmount > maxFeeAmount) {
            effectiveFeeAmount = maxFeeAmount;
        }

        // send fee to operator
        _transferToken(operator, IERC20(feeToken), effectiveFeeAmount, true);

        emit FeePaid(feeToken, effectiveFeeAmount, operator);

        // calculate left tokens
        if (takeFeeFrom0) {
            amount0 -= effectiveFeeAmount;
        } else {
            amount1 -= effectiveFeeAmount;
        }

        return (amount0, amount1);
    }

    // transfers token (or unwraps WETH and sends ETH)
    function _transferToken(address to, IERC20 token, uint256 amount, bool unwrap) internal {
        if (address(weth) == address(token) && unwrap) {
            weth.withdraw(amount);
            (bool sent, ) = to.call{value: amount}("");
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