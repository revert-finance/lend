// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./compound/PriceOracle.sol";
import "./compound/ComptrollerInterface.sol";
import "./compound/Lens/CompoundLens.sol";
import "./compound/CErc20.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";

import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";
import 'v3-core/libraries/FixedPoint128.sol';

import "v3-periphery/libraries/LiquidityAmounts.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IInterestRateModel {
    // gets interest rate per second per unit of debt x96
    function getRateX96(uint supply, uint debt) external view returns (uint256 result);
}

interface IOracle {
    // gets price for a given token in USD(C)
    function getPriceX96(address token) external view returns (uint256 result);
}

interface IVaultCallback {
    // callback after requesting access to collateral for modifying
    function modifyCallback() external;
}

/// @title Vault for token lending / borrowing using LP positions as collateral
contract Vault is Ownable {

    uint constant Q32 = 2 ** 32;
    uint constant Q96 = 2 ** 96;
    uint constant MAX_COLLATERAL_FACTOR = Q32 * 90 / 100; // 90%

    /// @notice Uniswap v3 position manager
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    /// @notice Uniswap v3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice Token which is lent in this vault
    IERC20 immutable public lendToken;

    error Reentrancy();
    error NotOwner();
    error WrongContract();
    error CollateralFail();
    error GlobalDebtLimit();
    error GlobalLendLimit();
    error InsufficientLiquidity();
    error NotLiquidatable();
    error InterestNotUpdated();
    error TransformerNotAllowed();
    error TransformFailed();
    error CollateralFactorExceedsMax();
  
    IInterestRateModel public interestRateModel;
    IOracle public oracle;

    struct TokenConfig {
        uint32 collateralFactorX32;
        uint collateralAmount;
    }
    mapping(address => TokenConfig) public tokenConfigs;

    // percentage of interest which is kept in the protocol for reserves
    uint32 reserveFactorX32;

    // percentage of lend amount which needs to be in reserves before withdrawn
    uint32 reserveProtectionFactorX32;

    uint globalReserveAmount;

    uint globalDebtAmount;
    uint globalDebtLimit;

    uint globalLendAmount;
    uint globalLendLimit;

    uint lastInterestUpdate;
    uint lastInterestTotalX96;

    struct Lender {
        uint256 lastInterestUpdate;
        uint256 lastInterestTotalX96;
        uint256 amount;
    }
    mapping(address => Lender) public lenders;

    struct Loan {
        uint tokenId;        
        address owner;
        uint lastInterestUpdate;
        uint lastInterestTotalX96;
        uint amount;
    }
    uint loanCount;
    mapping(uint => Loan) loans;

    // contracts allowed to transform positions
    uint transformerLoanId; // transient (when available)
    mapping(address => bool) transformerAllowList;

    constructor(INonfungiblePositionManager _nonfungiblePositionManager, IERC20 _lendToken, IInterestRateModel _interestRateModel, IOracle _oracle) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        lendToken = _lendToken;
        interestRateModel = _interestRateModel;
        oracle = _oracle;
    }

    ////////////////// EXTERNAL FUNCTIONS

    function create(uint256 tokenId, uint amount) external {
        nonfungiblePositionManager.transferFrom(tokenId, msg.sender, address(this), abi.encode(msg.sender, amount));
    }

    function createWithPermit(uint256 tokenId, address owner, uint amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        nonfungiblePositionManager.permit(address(this), tokenId, deadline, v, r, s);
        nonfungiblePositionManager.transferFrom(tokenId, owner, address(this), abi.encode(owner, amount));
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        // only Uniswap v3 NFTs allowed - sent from other contract
        if (msg.sender != address(nonfungiblePositionManager) || from == address(this)) {
            revert WrongContract();
        }

        (address owner, uint amount) = abi.decode(data, (address, uint));

        uint loanId = transformerLoanId;
        if (loanId == 0) {
            _updateGlobalInterest();
            loanId = ++loanCount;
            loans[loanId] = Loan(tokenId, owner, block.timestamp, lastInterestTotalX96, 0);

            // direct borrow if requested
            if (amount > 0) {
                _borrow(loanId, amount, false, true);
            }
        } else {
            // if in transform mode - current token is replaced
            loans[loanId].tokenId = tokenId;
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    // method which allows a contract to transform a loan by borrowing and adding collateral in an atomic fashion
    function transform(uint loanId, address transformer, bytes calldata data) external {
        if (!transformerAllowList[transformer]) {
            revert TransformerNotAllowed();
        }
        if (transformerLoanId > 0) {
            revert Reentrancy();
        }
        transformerLoanId = loanId;

        Loan storage loan = loans[loanId];
        if (loan.owner != msg.sender) {
            revert NotOwner();
        }

        _updateGlobalInterest();
        _updateLoanInterest(loanId);

        // give access to transformer
        nonfungiblePositionManager.approve(loan.tokenId, transformer);

        (bool success,) = transformer.call(data);
        if (!success) {
            revert TransformFailed();
        }
        
        // check owner not changed (NEEDED beacuse approvalForAll could be set which would fake complete ownership)
        address owner = nonfungiblePositionManager.ownerOf(loan.tokenId);
        if (owner != address(this)) {
            revert NotOwner();
        }

        // remove access for msg.sender
        nonfungiblePositionManager.approve(loan.tokenId, address(0));

        _requireLoanIsHealthy(loanId);

        transformerLoanId = 0;
    }

    function borrow(uint loanId, uint amount) external {

        bool isTransformMode = transformerLoanId > 0 && transformerLoanId == loanId && transformerAllowList[msg.sender];

        // if not in transform mode - caller must be owner
        if (!isTransformMode) {
            _borrow(loanId, amount, true, true);
        } else {
            _borrow(loanId, amount, false, false);
        }
    }

    function _borrow(uint loanId, uint amount, bool doOwnerCheck, bool doHealthCheck) internal {

        Loan storage loan = loans[loanId];

        if (doOwnerCheck && loan.owner != msg.sender) {
            revert NotOwner();
        }
        _updateGlobalInterest();
        _updateLoanInterest(loanId);

        loan.amount += amount;
        globalDebtAmount += amount;

        if (globalDebtAmount > globalDebtLimit) {
            revert GlobalDebtLimit();
        }

        // fails if not enough lendToken available
        // if called from transform mode - send funds to transformer contract
        lendToken.transfer(!doHealthCheck ? msg.sender : loan.owner, amount);

        // only check health if not in transform mode
        if (doHealthCheck) {
            _requireLoanIsHealthy(loanId);
        }
    }

    function repay(uint loanId, uint amount) external {

        _updateGlobalInterest();
        _updateLoanInterest(loanId);

        Loan storage loan = loans[loanId];

        if (amount > loan.amount) {
            amount = loan.amount;
        }

        if (amount > 0) {
            lendToken.transferFrom(msg.sender, address(this), amount);
        }

        loan.amount -= amount;
        globalDebtAmount -= amount;

        // if fully repayed - nft is returned
        if (loan.amount == 0) {
            loan.tokenId = 0;
            nonfungiblePositionManager.safeTransferFrom(loan.tokenId, address(this), loan.owner);
        }
    }

    function deposit(uint256 amount) external {

        _updateGlobalInterest();
        _updateLenderInterest(msg.sender);
        
        lendToken.transferFrom(msg.sender, address(this), amount);
        lenders[msg.sender].amount += amount;
        globalLendAmount += amount;

        if (globalLendAmount > globalLendLimit) {
            revert GlobalLendLimit();
        }
    }

    function withdraw(uint256 amount) external {
        
        _updateGlobalInterest();
        _updateLenderInterest(msg.sender);
        
        if (amount > lenders[msg.sender].amount) {
            amount = lenders[msg.sender].amount;
        }

        uint balance = lendToken.balanceOf(address(this));
        uint available = balance > globalReserveAmount ? balance - globalReserveAmount : 0;

        if (available < amount) {
            revert InsufficientLiquidity();
        }

        lenders[msg.sender].amount -= amount;
        lendToken.transfer(msg.sender, amount);
    }

    // function to liquidate position - needed lendtokens depending on current price
    function liquidate(uint loanId) external {

        // liquidation is not allowed during transformer mode
        if (transformerLoanId > 0) {
            revert TransformerNotAllowed();
        }

        _updateGlobalInterest();
        _updateLoanInterest(loanId);

        (bool isHealthy, uint fullValue, uint collateralValue) = _checkLoanIsHealthy(loanId);
        if (isHealthy) {
            revert NotLiquidatable();
        }

        (uint leftover, uint liquidatorCost, uint reserveCost) = _calculateLiquidation(loans[loanId].amount, fullValue, collateralValue);

        // take value from liquidator
        lendToken.transferFrom(msg.sender, address(this), liquidatorCost);
        
        // take remaining amount from reserves - if not enough - democratize debt
        if (reserveCost > 0) {
            if (reserveCost < globalReserveAmount) {
                globalReserveAmount -= reserveCost;
            } else {
                uint missing = reserveCost - globalReserveAmount;
                globalReserveAmount = 0;

                //TODO magic formula to calculate interest total to account for loss
                lastInterestTotalX96 = 0;
            }
        }

        Loan storage loan = loans[loanId];
        globalDebtAmount -= loan.amount;
        loan.amount = 0;
        nonfungiblePositionManager.safeTransfer(loan.tokenId, address(this), msg.sender);
    }


    // calculates amount which needs to be payed to liquidate position - if it doesn't have enough value anymore - part is covered by reserves
    function _calculateLiquidation(uint debt, uint fullValue, uint collateralValue) internal returns (uint leftover, uint liquidatorCost, uint reserveCost) {

        uint MIN_LIQUIDATION_PENALTY_X32 = 0;
        uint MAX_LIQUIDATION_PENALTY_X32 = Q32 / 10; // 10%
        uint UNDERWATER_LIQUIDATION_PENALTY_X32 = Q32 / 20; // 5%

        uint maxPenaltyValue = debt * (Q32 + MAX_LIQUIDATION_PENALTY_X32) / Q32;
        uint underwaterPenaltyValue = debt * (Q32 + UNDERWATER_LIQUIDATION_PENALTY_X32) / Q32;

        uint fullDebt = debt * fullValue / collateralValue;

        if (fullValue > maxPenaltyValue) {
            uint penaltyX32 = MAX_LIQUIDATION_PENALTY_X32 * (Q96 - ((fullValue - maxPenaltyValue) * Q96 / (fullDebt - maxPenaltyValue))) / Q96;
            uint penaltyValue = fullValue * (Q32 - penaltyX32) / Q32;
            leftover = penaltyValue - debt;
            liquidatorCost = penaltyValue;
        } else {
            if (fullValue > underwaterPenaltyValue) {
                // TODO calculate
            } else {
                uint penaltyValue = fullValue * (Q32 - UNDERWATER_LIQUIDATION_PENALTY_X32) / Q32;
                liquidatorCost = penaltyValue;
                reserveCost = debt - penaltyValue;
            }
        }
    }


    ////////////////// ADMIN FUNCTIONS only callable by owner

    // function to withdraw protocol reserves 
    // only allows to withdraw excess reserves (> globalLendAmount * reserveProtectionFactor)
    function withdrawReserves(uint256 amount, address account) external onlyOwner {
        
        _updateGlobalInterest();
       
        uint protected = globalLendAmount * reserveProtectionFactorX32 / Q32;
        uint unprotected = globalReserveAmount > protected ? globalReserveAmount - protected : 0;
        uint balance = lendToken.balanceOf(address(this));
        uint available = balance > unprotected ? unprotected : balance;

        if (amount > available) {
            amount = available;
        }

        if (amount > 0) {
            globalReserveAmount -= amount;
            lendToken.transfer(account, amount);
        }
    }

    // function to configure transformer contract 
    function setTransformer(address transformer, bool active) external onlyOwner {
        transformerAllowList[transformer] = active;
    }

    // function to set limits (this doesnt affect existing loans)
    function setLimits(uint _globalLendLimit, uint _globalDebtLimit) external onlyOwner {
        globalLendLimit = _globalLendLimit;
        globalDebtLimit = _globalDebtLimit;
    }

    // function to set reserve factor - percentage difference between borrowing and lending interest
    function setReserveFactor(uint32 _reserveFactorX32) external onlyOwner {
        reserveFactorX32 = _reserveFactorX32;
    }

    // function to set reserve protection factor - percentage of globalLendAmount which can't be withdrawn by owner
    function setReserveProtectionFactor(uint32 _reserveProtectionFactorX32) external onlyOwner {
        reserveProtectionFactorX32 = _reserveProtectionFactorX32;
    }

    // function to set collateral factor for a given token
    function setTokenConfig(address token, uint32 collateralFactorX32) external onlyOwner {
        if (collateralFactorX32 > MAX_COLLATERAL_FACTOR) {
            revert CollateralFactorExceedsMax();
        }
        tokenConfigs[token] = TokenConfig(collateralFactorX32);
    }

    ////////////////// INTERNAL FUNCTIONS

    function _setTokenCollateral(uint loanId, uint tokenId) internal {
        Loan storage loan = loans[loanId];

        (address token0, address token1, uint amount0, uint amount1) = _getPositionBreakdown(tokenId, true);

        if (loan.collateral0 > 0 || loan.collateral1 > 0) {

            address previousToken0 = token0;
            address previousToken1 = token1;

            // check if same tokenid - otherwise load 
            if (tokenId != loan.tokenId) {
                 (, ,previousToken0 ,previousToken1 , , , , , , , , ) = nonfungiblePositionManager.positions(tokenId);
            }

            tokenConfigs[previousToken0].collateralAmount -= loan.collateral0;
            tokenConfigs[previousToken1].collateralAmount -= loan.collateral1;
        }
        
        tokenConfigs[token0].collateralAmount += amount0;
        tokenConfigs[token1].collateralAmount += amount1;

        loan.tokenId = tokenId;
        loan.token0 = token0;
        loan.token1 = token1;
        loan.collateral0 = amount0;
        loan.collateral1 = amount1;
    }

    // updates loan by calculating interest
    function _updateLoanInterest(uint loanId) internal {
        Loan storage loan = loans[loanId];

        if (block.timestamp > loan.lastInterestUpdate) {
            uint interest = _calculateInterest(loan.amount, loan.lastInterestUpdate, loan.lastInterestTotalX96, true);
            loan.amount += interest;
            loan.lastInterestUpdate = block.timestamp;
            loan.lastInterestTotalX96 = lastInterestTotalX96;
        }
    }

    function _updateLenderInterest(address lenderAddress) internal {
        Lender storage lender = lenders[lenderAddress];

        if (block.timestamp > lender.lastInterestUpdate) {
            uint interest = _calculateInterest(lender.amount, lender.lastInterestUpdate, lender.lastInterestTotalX96, false);
            lender.amount += interest;
            lender.lastInterestUpdate = block.timestamp;
            lender.lastInterestTotalX96 = lastInterestTotalX96;
        }
    }

    function _updateGlobalInterest() internal {
        if (block.timestamp > lastInterestUpdate) {
            uint rateX96 = interestRateModel.getRateX96(globalLendAmount, globalDebtAmount);
            uint interestX96 = (block.timestamp - lastInterestUpdate) * rateX96;
            lastInterestTotalX96 += lastInterestTotalX96 * interestX96 / Q96;
            lastInterestUpdate = block.timestamp;

            uint debtGrowth = globalDebtAmount * interestX96 / Q96;
            globalDebtAmount += debtGrowth;
            globalLendAmount += debtGrowth * (Q32 - reserveFactorX32) / Q32;
            globalReserveAmount += debtGrowth * reserveFactorX32 / Q32;
        }
    }

    function _requireLoanIsHealthy(uint loanId) internal {
        (bool isHealthy, ) = _checkLoanIsHealthy(loanId);
        if (!isHealthy) {
            revert CollateralFail();
        }
    }

    function _checkLoanIsHealthy(uint loanId) internal returns (bool isHealty, uint fullValue, uint collateralValue) {
        // loan must be updated with interests at this point
        if (loans[loanId].lastInterestUpdate != block.timestamp) {
            revert InterestNotUpdated();
        }

        (fullValue, collateralValue) = _calculateCollateralValue(loanId);
        isHealty = collateralValue >= loans[loanId].amount;
    }

    function _calculateInterest(uint amount, uint lastUpdate, uint lastTotalX96, bool isBorrower) internal returns (uint) {
        return amount * (block.timestamp - lastUpdate) * (lastInterestTotalX96 - lastTotalX96) / Q96 * (isBorrower ? Q32 : Q32 - reserveFactorX32) / Q32;
    }

    function _calculateCollateralValue(uint loanId) internal returns (uint fullValue, uint collateralValue) {

        Loan memory loan = loans[loanId];

        (address token0, address token1, uint amount0, uint amount1) = _getPositionBreakdown(loan.tokenId, false);

        uint value0 = oracle.getPriceX96(token0) * amount0 / Q96;
        uint value1 = oracle.getPriceX96(token1) * amount1 / Q96;

        fullValue = value0 + value1;
        collateralValue = value0 * tokenConfigs[token0].collateralFactorX32 / Q32 + value1 * tokenConfigs[token1].collateralFactorX32 / Q32;
    }

    // returns token breakdown (optional return max possible amounts given current fees)
    function _getPositionBreakdown(uint256 tokenId, bool maxAmounts) internal view returns (address token0, address token1, uint256 amount0, uint256 amount1) {

        PositionState memory position = _getPositionState(tokenId);

        // get current tick needed for uncollected fees calculation
        (uint160 sqrtPriceX96, int24 tick,,,,,) = position.pool.slot0();

        // calculate position amounts (incl uncollected fees)
        (amount0, amount1) = _getAmounts(position, sqrtPriceX96, tick, maxAmounts);

        // return used tokens
        token0 = position.token0;
        token1 = position.token1;
    }

    struct PositionState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        IUniswapV3Pool pool;
    }

    // loads position state
    function _getPositionState(uint256 tokenId) internal view returns (PositionState memory state) {
        (
            ,
            ,
            state.token0,
            state.token1,
            state.fee,
            state.tickLower,
            state.tickUpper,
            state.liquidity,
            state.feeGrowthInside0LastX128,
            state.feeGrowthInside1LastX128,
            state.tokensOwed0,
            state.tokensOwed1
        ) = nonfungiblePositionManager.positions(tokenId);

        state.pool = _getPool(state.token0, state.token1, state.fee);
    }

    // calculate position amounts given current price/tick
    function _getAmounts(PositionState memory position, uint160 sqrtPriceX96, int24 tick, bool maxAmounts) internal view returns (uint256 amount0, uint256 amount1) {
        if (position.liquidity > 0) {
            uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(position.tickLower);
            uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(position.tickUpper);        
            if (maxAmounts) {
                amount0 = LiquidityAmounts.getAmount0ForLiquidity(sqrtPriceX96Lower, sqrtPriceX96Upper, position.liquidity);
                amount1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtPriceX96Lower, sqrtPriceX96Upper, position.liquidity);
            } else {
                (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceX96Lower, sqrtPriceX96Upper, position.liquidity);
            }
        }

        (uint256 fees0, uint256 fees1) = _getUncollectedFees(position, tick);
        amount0 += fees0 + position.tokensOwed0;
        amount1 += fees1 + position.tokensOwed1;
    }

    // calculate uncollected fees
    function _getUncollectedFees(PositionState memory position, int24 tick) internal view returns (uint256 fees0, uint256 fees1)
    {
        (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = _getFeeGrowthInside(
            position.pool,
            position.tickLower,
            position.tickUpper,
            tick,
            position.pool.feeGrowthGlobal0X128(),
            position.pool.feeGrowthGlobal1X128()
        );

        fees0 = FullMath.mulDiv(feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128, position.liquidity, FixedPoint128.Q128);
        fees1 = FullMath.mulDiv(feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128, position.liquidity, FixedPoint128.Q128);
    }

    // calculate fee growth for uncollected fees calculation
    function _getFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) = pool.ticks(tickLower);
        (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) = pool.ticks(tickUpper);

        // calculate fee growth below
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0X128 = lowerFeeGrowthOutside0X128;
            feeGrowthBelow1X128 = lowerFeeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128;
        }

        // calculate fee growth above
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upperFeeGrowthOutside0X128;
            feeGrowthAbove1X128 = upperFeeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upperFeeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upperFeeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    // helper method to get pool for token
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(address(factory), PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }
}