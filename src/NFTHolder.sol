// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./external/uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import "./external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./external/compound/ComptrollerInterface.sol";
import "./external/compound/CToken.sol";

import "./ISwapRouter.sol";

contract NFTHolder {

    uint32 constant public MAX_TOKENS_PER_ADDRESS = 100;

    address immutable public weth;

    // uniswap v3 components
    IUniswapV3Factory immutable public factory;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    // generic router interface - exchangable by owner
    ISwapRouter public swapRouter;

    // compound components
    ComptrollerInterface immutable public comptroller;


    // ISwapRouter maybe Uniswap or 1Inch or something else
    constructor(address _weth, IUniswapV3Factory _factory, INonfungiblePositionManager _nonfungiblePositionManager, ISwapRouter _swapRouter, ComptrollerInterface _comptroller) {
        weth = _weth;
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
        comptroller = _comptroller;
    }

    // amount of position value which is payed from treasury for late in() / out() calls
    uint256 public punishmentFactor;

    struct PoolConfig {
        uint32 bufferZoneTicks;
        bool isActive;
        uint32 collateralFactor;
        address cToken0;
        address cToken1;
    }

    mapping(address => PoolConfig) poolConfigs;

    struct Token {
        address owner;
        uint128 originalLiquidity;
        address pool;

        bool isAutoCompoundable;
        bool isCollateralizable;
        bool isLendable;

        // if not enough capital available for unlend() or if position was changed by owner in buffer zone
        bool isProtected;

         // if > 0 - lent out
        uint128 cTokenAmount;
        bool isCToken0;
    }

    mapping(uint256 => Token) tokens;
    mapping(address => uint256[]) public override accountTokens;
    mapping(address => mapping(address => uint256)) public override accountBalances;

    function onERC721Received(address operator, address from, uint256 tokenId, bytes data) external  {

        _addToken(tokenId, from);

        bool isAutoCompoundable; 
        bool isCollateralizable;
        bool isLendable;
        (isAutoCompoundable, isCollateralizable, isLendable) = abi.decode(data, (bool, bool, bool));

        configToken(tokenId, isAutoCompoundable, isCollateralizable, isLendable);

        // TODO special case: change range and withdraw
        // TODO special case: autocompound and withdraw
    }

    // sets tokens config flags - changes state when needed
    function configToken(uint tokenId, bool isAutoCompoundable, bool isCollateralizable, bool isLendable) public {

        Token storage position = tokens[tokenId];

        require(position.owner != address(0), "!found");

        PoolConfig storage poolConfig = poolConfigs[position.pool];

        if (position.isAutoCompoundable != isAutoCompoundable) {
            position.isAutoCompoundable = isAutoCompoundable;
        }

        if (position.isCollateralizable != isCollateralizable) {
            position.isCollateralizable = isCollateralizable;

            // if its removed from collateral - check if enough left
            if (!isCollateralizable) {
                // comptroller.checkCollateral()
            }
        }
        
        if (position.isLendable != isLendable) {
            position.isLendable = isLendable;
            bool isProtected;
            if (isLendable) {
                isProtected = lend(position);
            } else {
                isProtected = unlend(position);
            }
            position.isProtected = isProtected; // set flag depending on when
        }   
    }

    function withdrawToken(
        uint256 tokenId,
        address to,
        bool withdrawBalances,
        bytes memory data
    ) external override nonReentrant {
        require(to != address(this), "to==this");

        Token storage token = tokens[tokenId];
        require(token.owner == msg.sender, "!owner");

        if (token.cTokenAmount > 0) {
            unlend(token);
        }

        _removeToken(tokenId, msg.sender);
        nonfungibleTokenManager.safeTransferFrom(address(this), to, tokenId, data);

        if (withdrawBalances) {
            (, , address token0, address token1, , , , , , , , ) = nonfungibleTokenManager.tokens(tokenId);
            _withdrawFullBalances(token0, token1, to);
        }
    }

    function balanceOf(address account) external view {
        return accountTokens[account].length;
    }

    function ownerOf(uint tokenId) external {
        return tokens[tokenId].owner;
    }

    function mint(address token0, address token1, int24 fee, int24 lowerTick, int24 upperTick, uint amount0, uint amount1, bool add, bool borrow, bool isAutoCompoundable, bool isCollateralizable, bool isLendable, bool swap0For1, uint swapAmount, bytes calldata swapData) external {

        if (!borrow) {
            _prepareAdd(token0, token1, amount0, amount1);
            if (swapAmount > 0) {
                uint swappedAmount = _swap(swap0For1 ? token0 : token1, swap0For1 ? token1 : token0, swapAmount, swapData);
                if (swap0For1) {
                    amount0 -= swapAmount;
                    amount1 += swappedAmount;
                } else {
                    amount1 -= swapAmount;
                    amount0 += swappedAmount;
                }
            }
        } else {
            address poolAddress = factory.getPool(token0, token1, fee);
            PoolConfig storage poolConfig = poolConfigs[poolAddress];
            if (amount0 > 0) {
                CToken(poolConfig.cToken0).borrow(amount0);
            }
            if (amount1 > 0) {
                CToken(poolConfig.cToken1).borrow(amount1);
            }
        }

        if (amount0 > 0) {
            IERC20(token0).approve(address(nonfungiblePositionManager), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).approve(address(nonfungiblePositionManager), amount1);
        }

        INonfungiblePositionManager.MintParams memory mintParams = 
            INonfungiblePositionManager.MintParams(
                params.token0, 
                params.token1, 
                params.fee, 
                params.tickLower, 
                params.tickUpper,
                amount0, 
                amount1, 
                0,
                0,
                address(this),
                block.timestamp
            );

        (uint tokenId,,uint addedAmount0, uint addedAmount1) = nonfungiblePositionManager.mint(mintParams);

        // add 
        if (addedAmount0 < amount0) {
            _increaseBalance(msg.sender, token0, amount0 - addedAmount0);
        }
        if (addedAmount1 < amount1) {
            _increaseBalance(msg.sender, token1, amount1 - addedAmount1);
        }

        // get tokens from msg.sender - like in the old compounder
        // swap provided tokens with given instructions in data
        // create position
        // return leftovers - or add to account balances
        
        if (add) {
            _addToken(tokenId, msg.sender);
            configToken(tokenId, isAutoCompoundable, isCollateralizable, isLendable);
        } else {
            _withdrawFullBalances(token0, token1, msg.sender);
            nonfungibleTokenManager.safeTransferFrom(address(this), msg.sender, tokenId, "0x");
        }

        if (borrow) {
            comptroller.checkCollateral();
        }
    }

    function increase(uint tokenId, uint amount0, uint amount1, bool returnLeftovers, bytes swapData) external {

        _prepareAdd(token0, token1, amount0, amount1);

        // get tokens from msg.sender - like in the old compounder
        // swap provided tokens with given instructions in data
        // add liquidity
        // return leftovers - or add to account balances

        if (returnLeftovers) {
            _withdrawFullBalances(token0, token1, msg.sender);
        } else {

        }
    }

    function changeRange(uint tokenId, uint lower, uint upper, bytes swapData) external {

        Token storage token = tokens[tokenId];
        require(token.owner == msg.sender, "!owner");

        if (token.cTokenAmount > 0) {
            unlend();
        }

        (,,,,,,,uint128  liquidity,,,) = nonfungiblePositionManager.positions(tokenId);

        _decreaseLiquidity(tokenId, liquidity);
        (uint amount0, uint amount1) = _collectFees(tokenId);

        _removeToken(tokenId, msg.sender);

        uint newTokenId = _mintAndSwap(amount0, amount1, swapData); // TODO create internal function - add all parameters needed

        _addToken(newTokenId, msg.sender);

        if (token.isCollateralizable) {
            comptroller.checkCollateral();
        }
    }

    function decreaseLiquidityAndCollect(uint tokenId, bool repay) external {
        // decreaseLiquidityAndCollect

        // optionally repay debt

        // if (isCollateralizable) comptroller.checkCollateral()
    }

    function collect(uint tokenId, bool repay) external {
        // collect

        // optionally repay debt

        // if (isCollateralizable) comptroller.checkCollateral()
    }

    // management method to be called when isLendable positions change from out of range towards in range
    function in(uint tokenId, bytes swapData) external {
        
        // if out of range - only owner or protocol can call this
        // if in range & !isProtected - anyone can call it
        // if in range & isProtected - only owner can call it

        // check if isLendable (only needed for these tokens)

        // unlend() or unlendWithSwap(swapData) if in range

        // can be called again when liquidity becomes available at a later moment

        // if !isProtected - pay position value * punishmentFactor
    }

    // management method to be called when isLendable positions change from in range towards out of range (and buffer zone)
    function out(uint tokenId) external {
        
        // if in range or buffer zone - only owner or protocol can call this
        // if out of range and buffer zone - anyone can call it


        // check if isLendable (only needed for these tokens)

        // lend()

        // if !isProtected - pay position value * punishmentFactor
    }

    // borrow tokens to be added to the position
    function borrow(uint tokenId, uint liquidity) external {

        // only owner

        // borrow needed tokens (without comptroller.checkCollateral() - flashloan style)

        // add liquidity or add ctokens (if in lent state)

        // comptroller.checkCollateral()
    }

    // repay tokens from the position
    function repay(uint tokenId, uint liquidity, bool swap) external {

        // only owner

        // remove liquidity

        // repay tokens - without swapping - needs to have enough debt in both tokens
        
        // comptroller.checkCollateral()
    }

    function autoCompound(uint tokenId) external {
        
        
        // do autocompounding (optional with swap config - check swapped amounts to be min 99?% of swap amounts - check min added amount to position to be 80?%)

        // comptroller.checkCollateral()
    }

    function lend(Token storage token) internal {
        
        // must be out of range / must not have ctoken balance

        // remove all liquidity (one sided)
        // supply to ctoken
        // store in position token balance (ctoken balance)

        // comptroller.checkCollateral()
    }

    function unlend(Token storage token) internal {

        // must be out of range / must have ctoken balance

        // try to reedeem ctokens from position (without comptroller.checkCollateral() - flashloan style)
        // if not enough tokens available - set isProtectedFromPunishment - stop

        // add liquidity

        // comptroller.checkCollateral()
    }

    function unlendWithSwap(Token storage token, bytes data) internal {

        // must have ctoken balance
        // if !isProtected && in force zone - anyone can call this
        // if isProtected && in force zone - owner can call this

        // try to reedeem ctokens from position (without comptroller.checkCollateral() - flashloan style) - if not enough set to isProtected - stop

        // swap according to data
        // check if recieved token from swap are enough (slippage was respected) - as this can be called by anyone

        // add liquidity
        
        // if !isProtected - add from treasury missing tokens

        // comptroller.checkCollateral()
    }







    function _supportsLending(uint256 tokenId) internal {
        // check pool configs
    }

    function _addToken(uint256 tokenId, address account) internal {

        require(accountTokens[account].length < MAX_TOKENS_PER_ADDRESS, "max tokens reached");

        // get tokens for this nft
        (, , address token0, address token1, uint24 fee, , , uint128 liquidity , , , , ) = nonfungibleTokenManager.tokens(tokenId);

        address pool = factory.getPool(token0, token1, fee);


        _checkApprovals(IERC20(token0), IERC20(token1));

        accountTokens[account].push(tokenId);
        tokens[tokenId] = new Token(account, liquidity, pool, false, false, false, false, 0, false);
    }

    function _removeToken(uint256 tokenId, address account) internal {
        uint256[] memory accountTokensArr = accountTokens[account];
        uint256 len = accountTokensArr.length;
        uint256 assetIndex = len;

        // limited by MAX_POSITIONS_PER_ADDRESS (no out-of-gas problem)
        for (uint256 i = 0; i < len; i++) {
            if (accountTokensArr[i] == tokenId) {
                assetIndex = i;
                break;
            }
        }

        assert(assetIndex < len);

        uint256[] storage storedList = accountTokens[account];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        delete tokens[tokenId];
    }

    // collect all available fees
    function _collectFees(uint tokenId) external returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)
        );
    }

    // decrease liquidity
    function _decreaseLiquidity(uint tokenId, uint128 liquidity) 
        override 
        external   
        returns (uint256 amount0, uint256 amount1) 
    {
        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(
                tokenId, 
                liquidity, 
                0, 
                0,
                block.timestamp
            )
        );

        INonfungiblePositionManager.CollectParams memory collectParams = 
            INonfungiblePositionManager.CollectParams(
                tokenId, 
                address(this), 
                type(uint128).max, 
                type(uint128).max
            );

        nonfungiblePositionManager.collect(collectParams);
    }

    function _increaseBalance(address account, address token, uint256 amount) internal {
        accountBalances[account][token] = accountBalances[account][token] + amount;
        emit BalanceAdded(account, token, amount);
    }

    function _setBalance(address account, address token, uint256 amount) internal {
        uint currentBalance = accountBalances[account][token];
        
        if (amount > currentBalance) {
            accountBalances[account][token] = amount;
            emit BalanceAdded(account, token, amount - currentBalance);
        } else if (amount < currentBalance) {
            accountBalances[account][token] = amount;
            emit BalanceRemoved(account, token, currentBalance - amount);
        }
    }

    function _withdrawFullBalances(address token0, address token1, address to) internal {
        uint256 balance0 = accountBalances[msg.sender][token0];
        if (balance0 > 0) {
            _withdrawBalanceInternal(token0, to, balance0, balance0);
        }
        uint256 balance1 = accountBalances[msg.sender][token1];
        if (balance1 > 0) {
            _withdrawBalanceInternal(token1, to, balance1, balance1);
        }
    }

    function _withdrawBalanceInternal(address token, address to, uint256 balance, uint256 amount) internal {
        require(amount <= balance, "amount>balance");
        accountBalances[msg.sender][token] -= amount;
        emit BalanceRemoved(msg.sender, token, amount);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit BalanceWithdrawn(msg.sender, token, to, amount);
    }

    // prepares adding specified amounts, handles weth wrapping, reverts when more than necessary is added
    function _prepareAdd(address token0, address token1, uint amount0, uint amount1) internal returns (uint amountAdded0, uint amountAdded1)
    {
        // wrap ether sent
        if (msg.value > 0) {
            (bool success,) = payable(weth).call{ value: msg.value }("");
            require(success, "eth wrap fail");

            if (weth == token0) {
                amountAdded0 = msg.value;
                require(amountAdded0 <= amount0, "msg.value>amount0");
            } else if (weth == token1) {
                amountAdded1 = msg.value;
                require(amountAdded1 <= amount1, "msg.value>amount1");
            } else {
                revert("no weth token");
            }
        }

        // get missing tokens (fails if not enough provided)
        if (amount0 > amountAdded0) {
            uint balanceBefore = IERC20(token0).balanceOf(address(this));
            IERC20(token0).transferFrom(msg.sender, address(this), amount0 - amountAdded0);
            uint balanceAfter = IERC20(token0).balanceOf(address(this));
            require(balanceAfter - balanceBefore == amount0 - amountAdded0, "transfer error"); // catches any problems with deflationary or fee tokens
            amountAdded0 = amount0;
        }
        if (amount1 > amountAdded1) {
            uint balanceBefore = IERC20(token1).balanceOf(address(this));
            IERC20(token1).transferFrom(msg.sender, address(this), amount1 - amountAdded1);
            uint balanceAfter = IERC20(token1).balanceOf(address(this));
            require(balanceAfter - balanceBefore == amount1 - amountAdded1, "transfer error"); // catches any problems with deflationary or fee tokens
            amountAdded1 = amount1;
        }
    }

    // general swap function which uses external router with off-chain calculated swap instrucctions
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata swapData) internal returns (uint256 amountOut) {
        if (amount > 0) {
            uint balanceBefore = IERC20(tokenOut).balanceOf(address(this));
            IERC20(tokenIn).approve(address(swapRouter), amountIn);
            amountOut = swapRouter.swap(swapData);
            uint balanceAfter = IERC20(tokenOut).balanceOf(address(this));
            require(balanceAfter - balanceBefore == amountOut, "swap error"); // catches any problems with deflationary or fee tokens
        }
    }
}