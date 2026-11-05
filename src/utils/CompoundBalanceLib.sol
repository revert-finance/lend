// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-periphery/libraries/LiquidityAmounts.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "../interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IGaugeManager.sol";
import "../interfaces/ICompoundBalanceSource.sol";

interface ICarryGauge {
    function vault() external view returns (IVault);
    function aeroToken() external view returns (IERC20);
    function nonfungiblePositionManager() external view returns (INonfungiblePositionManager);
    function compoundBalanceSource() external view returns (address);
}

/// @dev Fixed linked library; executes in the automator's context. The caller owns the ledger and tokens.
/// Reentrancy guards remain on the external entrypoints. Owner and manager authorization below runs with
/// the original msg.sender under Solidity's fixed linked-library delegatecall.
library CompoundBalanceLib {
    event BalanceAdded(uint256 tokenId, address token, uint256 amount);
    event BalanceRemoved(uint256 tokenId, address token, uint256 amount);
    event BalanceWithdrawn(uint256 tokenId, address token, address to, uint256 amount);

    error InsufficientLiquidity();
    error Unauthorized();
    error InvalidConfig();
    error NotEnoughReward();

    struct Position {
        address token0;
        address token1;
        address rewardToken;
        address vault;
    }

    struct Ledger {
        mapping(uint256 => mapping(address => uint256)) balances;
        mapping(uint256 => Position) positions;
    }

    function collectFees(
        Ledger storage ledger,
        INonfungiblePositionManager npm,
        uint256 tokenId,
        uint128 min0,
        uint128 min1
    ) external returns (uint256 amount0, uint256 amount1, address token0, address token1, uint24 fee) {
        (amount0, amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)
        );
        if (amount0 < min0 || amount1 < min1) revert NotEnoughReward();
        (,, token0, token1, fee,,,,,,,) = npm.positions(tokenId);
        amount0 += ledger.balances[tokenId][token0];
        amount1 += ledger.balances[tokenId][token1];
    }

    function addLiquidityAndSettle(
        Ledger storage ledger,
        INonfungiblePositionManager npm,
        uint256 tokenId,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 rewardX64,
        uint256 deadline
    ) external returns (uint256 compounded0, uint256 compounded1, uint256 fee0, uint256 fee1) {
        ledger.positions[tokenId].token0 = token0;
        ledger.positions[tokenId].token1 = token1;
        (compounded0, compounded1, fee0, fee1) =
            _addLiquidity(npm, tokenId, token0, token1, amount0, amount1, rewardX64, deadline);
        _setBalance(ledger, tokenId, token0, amount0 - compounded0 - fee0);
        _setBalance(ledger, tokenId, token1, amount1 - compounded1 - fee1);
        _increaseBalance(ledger, 0, token0, fee0);
        _increaseBalance(ledger, 0, token1, fee1);
    }

    function addLiquidity(
        INonfungiblePositionManager npm,
        uint256 tokenId,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 rewardX64,
        uint256 deadline
    ) external returns (uint256 compounded0, uint256 compounded1, uint256 fee0, uint256 fee1) {
        return _addLiquidity(npm, tokenId, token0, token1, amount0, amount1, rewardX64, deadline);
    }

    function _addLiquidity(
        INonfungiblePositionManager npm,
        uint256 tokenId,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 rewardX64,
        uint256 deadline
    ) private returns (uint256 compounded0, uint256 compounded1, uint256 fee0, uint256 fee1) {
        uint256 Q64 = 2 ** 64;
        uint256 maxAddAmount0 = amount0 * Q64 / (rewardX64 + Q64);
        uint256 maxAddAmount1 = amount1 * Q64 / (rewardX64 + Q64);
        if ((maxAddAmount0 != 0 || maxAddAmount1 != 0) && _canAddLiquidity(npm, tokenId, maxAddAmount0, maxAddAmount1))
        {
            SafeERC20.safeIncreaseAllowance(IERC20(token0), address(npm), maxAddAmount0);
            SafeERC20.safeIncreaseAllowance(IERC20(token1), address(npm), maxAddAmount1);
            (, compounded0, compounded1) = npm.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId, maxAddAmount0, maxAddAmount1, 0, 0, deadline
                )
            );
            SafeERC20.safeApprove(IERC20(token0), address(npm), 0);
            SafeERC20.safeApprove(IERC20(token1), address(npm), 0);
            // Same fee calculation as the inline compounder: charge only the amounts actually added.
            fee0 = compounded0 * rewardX64 / Q64;
            fee1 = compounded1 * rewardX64 / Q64;
        }
    }

    /// @dev The NPM's own liquidity math, used only to skip a zero-liquidity mint. Saved dust must not
    /// roll back a preceding reward compound or staking switch. This is not a price/outcome threshold.
    function _canAddLiquidity(INonfungiblePositionManager npm, uint256 tokenId, uint256 amount0, uint256 amount1)
        private
        view
        returns (bool)
    {
        (,, address token0, address token1, uint24 fee, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        address factory = npm.factory();
        // Same Aero-first / Uniswap fallback resolution as Swapper._getPool.
        (bool success, bytes memory data) = factory.staticcall(
            abi.encodeWithSelector(IAerodromeSlipstreamFactory.getPool.selector, token0, token1, int24(fee))
        );
        address pool;
        if (success && data.length >= 32) pool = abi.decode(data, (address));
        if (pool == address(0)) pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        (success, data) = pool.staticcall(abi.encodeWithSelector(IUniswapV3Pool(pool).slot0.selector));
        if (!success || data.length < 64) revert InvalidConfig();
        return LiquidityAmounts.getLiquidityForAmounts(
            abi.decode(data, (uint160)),
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper),
            amount0,
            amount1
        ) != 0;
    }

    function takeRewards(address source, uint256 tokenId) external returns (uint256[3] memory saved) {
        if (source != address(0)) return ICompoundBalanceSource(source).compoundBalances(tokenId, false, saved);
    }

    function settleRewards(
        address source,
        address owner,
        uint256 tokenId,
        address[3] memory tokens,
        uint256[3] memory amounts
    ) external {
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] == 0) continue;
            if (source == address(0)) SafeERC20.safeTransfer(IERC20(tokens[i]), owner, amounts[i]);
            else SafeERC20.safeIncreaseAllowance(IERC20(tokens[i]), source, amounts[i]);
        }
        if (source != address(0)) {
            ICompoundBalanceSource(source).compoundBalances(tokenId, true, amounts);
            for (uint256 i; i < 3; ++i) {
                if (amounts[i] != 0) SafeERC20.safeApprove(IERC20(tokens[i]), source, 0);
            }
        }
    }

    function creditProtocolFees(Ledger storage ledger, address token0, address token1, uint256 fee0, uint256 fee1)
        external
    {
        _increaseBalance(ledger, 0, token0, fee0);
        _increaseBalance(ledger, 0, token1, fee1);
    }

    function ownerOf(
        Ledger storage ledger,
        INonfungiblePositionManager npm,
        mapping(address => bool) storage vaults,
        uint256 tokenId
    ) external returns (address owner, address realOwner) {
        return _ownerOf(ledger, npm, vaults, tokenId);
    }

    function _ownerOf(
        Ledger storage ledger,
        INonfungiblePositionManager npm,
        mapping(address => bool) storage vaults,
        uint256 tokenId
    ) private returns (address owner, address realOwner) {
        owner = npm.ownerOf(tokenId);
        if (vaults[owner]) return (owner, IVault(owner).ownerOf(tokenId));
        address positionVault = ledger.positions[tokenId].vault;
        if (positionVault != address(0) && vaults[positionVault]) {
            address manager = IVault(positionVault).gaugeManager();
            if (manager != address(0) && IGaugeManager(manager).tokenIdToGauge(tokenId) != address(0)) {
                return (owner, IVault(positionVault).ownerOf(tokenId));
            }
        }
        return (owner, owner);
    }

    function withdrawPosition(
        Ledger storage ledger,
        INonfungiblePositionManager npm,
        mapping(address => bool) storage vaults,
        uint256 tokenId,
        address to
    ) external {
        (, address owner) = _ownerOf(ledger, npm, vaults, tokenId);
        if (owner != msg.sender) revert Unauthorized();
        Position memory p = ledger.positions[tokenId];
        _withdrawAll(ledger, tokenId, p.token0, to);
        _withdrawAll(ledger, tokenId, p.token1, to);
        _withdrawAll(ledger, tokenId, p.rewardToken, to);
    }

    /// @dev Called only through the guarded automator entrypoint. Authenticate the registered vault's manager,
    /// never a caller-supplied list of assets or beneficiary. An active gauge binding authenticates its position.
    function rewardBalances(
        Ledger storage ledger,
        INonfungiblePositionManager npm,
        mapping(address => bool) storage vaults,
        uint256 tokenId,
        bool deposit,
        uint256[3] memory amounts
    ) external returns (uint256[3] memory taken) {
        IVault vault = ICarryGauge(msg.sender).vault();
        if (
            !vaults[address(vault)] || vault.gaugeManager() != msg.sender
                || address(ICarryGauge(msg.sender).nonfungiblePositionManager()) != address(npm)
                || ICarryGauge(msg.sender).compoundBalanceSource() != address(this)
                || IGaugeManager(msg.sender).tokenIdToGauge(tokenId) == address(0)
        ) revert Unauthorized();
        (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);
        address rewardToken = address(ICarryGauge(msg.sender).aeroToken());
        Position storage p = ledger.positions[tokenId];
        // The receipt asset cannot change underneath an outstanding position balance.
        if (p.rewardToken != address(0) && p.rewardToken != rewardToken && ledger.balances[tokenId][p.rewardToken] != 0)
        {
            revert InvalidConfig();
        }
        p.token0 = token0;
        p.token1 = token1;
        p.rewardToken = rewardToken;
        p.vault = address(vault);
        address[3] memory tokens = [token0, token1, rewardToken];
        for (uint256 i; i < 3; ++i) {
            address token = tokens[i];
            if (deposit) {
                if (amounts[i] == 0) continue;
                uint256 beforeBalance = IERC20(token).balanceOf(address(this));
                SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amounts[i]);
                if (IERC20(token).balanceOf(address(this)) - beforeBalance != amounts[i]) revert InvalidConfig();
                _increaseBalance(ledger, tokenId, token, amounts[i]);
            } else {
                // A receipt token that is also a pool token is withdrawn only once, as the pool token.
                taken[i] = ledger.balances[tokenId][token];
                _withdrawAll(ledger, tokenId, token, msg.sender);
            }
        }
    }

    /// @dev Only the automator's authenticated replacement path may call this. Same-pair balances move with the
    /// NFT; a change of assets settles to the old economic owner instead of creating unusable saved balances.
    function replacePosition(
        Ledger storage ledger,
        INonfungiblePositionManager npm,
        uint256 oldTokenId,
        uint256 newTokenId,
        address owner
    ) external {
        Position memory p = ledger.positions[oldTokenId];
        if (p.token0 == address(0)) return;
        (,, address token0, address token1,,,,,,,,) = npm.positions(newTokenId);
        bool samePair = token0 == p.token0 && token1 == p.token1;
        address[3] memory tokens = [p.token0, p.token1, p.rewardToken];
        for (uint256 i; i < 3; ++i) {
            uint256 amount = ledger.balances[oldTokenId][tokens[i]];
            if (amount == 0) continue;
            if (samePair) {
                _setBalance(ledger, oldTokenId, tokens[i], 0);
                _increaseBalance(ledger, newTokenId, tokens[i], amount);
            } else {
                _withdrawAll(ledger, oldTokenId, tokens[i], owner);
            }
        }
        if (samePair) {
            address existingReward = ledger.positions[newTokenId].rewardToken;
            if (p.rewardToken == address(0)) {
                p.rewardToken = existingReward;
            } else if (
                existingReward != address(0) && existingReward != p.rewardToken
                    && ledger.balances[newTokenId][existingReward] != 0
            ) {
                revert InvalidConfig();
            }
            ledger.positions[newTokenId] = p;
        }
        delete ledger.positions[oldTokenId];
    }

    function _withdrawAll(Ledger storage ledger, uint256 tokenId, address token, address to) private {
        uint256 amount = ledger.balances[tokenId][token];
        if (amount != 0) _withdrawBalanceInternal(ledger, tokenId, token, to, amount, amount);
    }

    function withdrawProtocolFees(Ledger storage ledger, address[] calldata tokens, address to) external {
        uint256 i;
        uint256 count = tokens.length;
        uint256 balance;
        address token;
        for (; i < count; ++i) {
            token = tokens[i];
            balance = ledger.balances[0][token];
            if (balance != 0) {
                _withdrawBalanceInternal(ledger, 0, token, to, balance, balance);
            }
        }
    }

    function _increaseBalance(Ledger storage ledger, uint256 tokenId, address token, uint256 amount) internal {
        ledger.balances[tokenId][token] += amount;
        emit BalanceAdded(tokenId, token, amount);
    }

    function _setBalance(Ledger storage ledger, uint256 tokenId, address token, uint256 amount) internal {
        uint256 currentBalance = ledger.balances[tokenId][token];
        if (amount != currentBalance) {
            ledger.balances[tokenId][token] = amount;
            if (amount > currentBalance) {
                emit BalanceAdded(tokenId, token, amount - currentBalance);
            } else {
                emit BalanceRemoved(tokenId, token, currentBalance - amount);
            }
        }
    }

    function _withdrawBalanceInternal(
        Ledger storage ledger,
        uint256 tokenId,
        address token,
        address to,
        uint256 balance,
        uint256 amount
    ) internal {
        if (amount > balance) {
            revert InsufficientLiquidity();
        }
        balance -= amount;
        ledger.balances[tokenId][token] = balance;
        emit BalanceRemoved(tokenId, token, amount);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit BalanceWithdrawn(tokenId, token, to, amount);
    }
}
