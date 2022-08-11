// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
                             
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

        // special case: change range and withdraw
        // special case: autocompound and withdraw
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

        Token storage position = tokens[tokenId];

        require(position.owner == msg.sender, "!owner");

        if (position.cTokenAmount > 0) {
            unlend();
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

    function mintAndSwap(bytes data) external {
        // get tokens from msg.sender - like in the old compounder
        // swap provided tokens with given instructions in data
        // create position
        // return leftovers - or add to account balances
        // return position - or add to contract
    }

    function increaseAndSwap(uint tokenId, bytes data) external {
        // get tokens from msg.sender - like in the old compounder
        // swap provided tokens with given instructions in data
        // add liquidity
        // return leftovers - or add to account balances
    }

    function changeRange(uint tokenId, uint lower, uint upper, bytes data) external {
        // if lent out - unlend()
        
        // remove all liquidity & fees
        // remove position from contract

        // mintAndSwap() - adding position to contract

        // if (isCollateralizable) comptroller.checkCollateral()
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

    function autocompound() external {
        // check if isAutoCompoundable
        
        // do autocompounding (optional with swap config - check swapped amounts to be min 99?% of swap amounts - check min added amount to position to be 80?%)

        // comptroller.checkCollateral()
    }

    function lend(Token storage position) internal {
        
        // must be out of range / must not have ctoken balance

        // remove all liquidity (one sided)
        // supply to ctoken
        // store in position token balance (ctoken balance)

        // comptroller.checkCollateral()
    }

    function unlend(Token storage position) internal {

        // must be out of range / must have ctoken balance

        // try to reedeem ctokens from position (without comptroller.checkCollateral() - flashloan style)
        // if not enough tokens available - set isProtectedFromPunishment - stop

        // add liquidity

        // comptroller.checkCollateral()
    }

    function unlendWithSwap(uint tokenId, bytes data) internal {

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
        accountBalances[msg.sender][token] = accountBalances[msg.sender][token].sub(amount);
        emit BalanceRemoved(msg.sender, token, amount);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit BalanceWithdrawn(msg.sender, token, to, amount);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amount, bytes data) internal returns (uint256 amountOut) {
        if (amount > 0) {
            //approve exact amount
            IERC20(token).approve(address(swapRouter), amount);
            uint amountOut = swapRouter.swap(data);
        }
    }
}