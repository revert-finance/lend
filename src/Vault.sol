// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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

import "./V3Oracle.sol";

interface IInterestRateModel {
    // gets interest rate per second per unit of debt x96
    function getBorrowRateX96(uint cash, uint debt) external view returns (uint256 result);
}

contract InterestRateModel is Ownable, IInterestRateModel {

    uint constant Q96 = 2 ** 96;

    uint public multiplierPerSecond;
    uint public baseRatePerSecond;
    uint public jumpMultiplierPerSecond;
    uint public kink;

    constructor(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) public {
        baseRatePerSecond = baseRatePerYear / 1 years;
        multiplierPerSecond = multiplierPerYear / 1 years;
        jumpMultiplierPerSecond = jumpMultiplierPerYear / 1 years;
        kink = kink_;
    }

    function getUtilizationRateX96(uint cash, uint debt) public pure returns (uint) {
        if (debt == 0) {
            return 0;
        }
        return debt * Q96 / (cash + debt);
    }

    function getBorrowRateX96(uint cash, uint debt) override external view returns (uint) {
        uint utilizationRateX96 = getUtilizationRateX96(cash, debt);

        if (utilizationRateX96 <= kink) {
            return (utilizationRateX96 * multiplierPerSecond / Q96) + baseRatePerSecond;
        } else {
            uint normalRate = (kink * multiplierPerSecond / Q96) + baseRatePerSecond;
            uint excessUtil = utilizationRateX96 - kink;
            return (excessUtil * jumpMultiplierPerSecond / Q96) + normalRate;
        }
    }

}


interface IVaultCallback {
    // callback after requesting access to collateral for modifying
    function modifyCallback() external;
}

/// @title Vault for token lending / borrowing using LP positions as collateral
contract Vault is Ownable, IERC721Receiver {

    uint constant Q32 = 2 ** 32;
    uint constant Q96 = 2 ** 96;
    uint constant MAX_COLLATERAL_FACTOR_X32 = Q32 * 90 / 100; // 90%

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
    IV3Oracle public oracle;

    struct TokenConfig {
        uint32 collateralFactorX32;
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
        uint32 collateralFactorX32; // assigned at loan creation
    }
    uint loanCount;
    mapping(uint => Loan) loans;

    // contracts allowed to transform positions
    uint transformerLoanId; // transient (when available)
    mapping(address => bool) transformerAllowList;

    constructor(INonfungiblePositionManager _nonfungiblePositionManager, IERC20 _lendToken, IInterestRateModel _interestRateModel, IV3Oracle _oracle) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        lendToken = _lendToken;
        interestRateModel = _interestRateModel;
        oracle = _oracle;
    }

    ////////////////// EXTERNAL FUNCTIONS

    function create(uint256 tokenId, uint amount) external {
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(msg.sender, amount));
    }

    function createWithPermit(uint256 tokenId, address owner, uint amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        nonfungiblePositionManager.permit(address(this), tokenId, deadline, v, r, s);
        nonfungiblePositionManager.safeTransferFrom(owner, address(this), tokenId, abi.encode(owner, amount));
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
            loans[loanId] = Loan(tokenId, owner, block.timestamp, lastInterestTotalX96, 0, _calculateTokenCollateralFactorX32(tokenId));

            // direct borrow if requested
            if (amount > 0) {
                _borrow(loanId, amount, false, true);
            }
        } else {
            // if in transform mode - current token is replaced
            if (loans[loanId].tokenId != tokenId) {
                loans[loanId].tokenId = tokenId;
                loans[loanId].collateralFactorX32 = _calculateTokenCollateralFactorX32(tokenId);
            }
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
        nonfungiblePositionManager.approve(transformer, loan.tokenId);

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
        nonfungiblePositionManager.approve(address(0), loan.tokenId);

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

    function repay(uint loanId, uint amount, bool withdrawNFT) external {

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

        // if fully repayed - and withdraw requested
        if (loan.amount == 0 && withdrawNFT) {
            uint tokenId = loan.tokenId;
            loan.tokenId = 0;
            nonfungiblePositionManager.safeTransferFrom(address(this), loan.owner, tokenId);
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
        
        uint tokenId = loan.tokenId;
        loan.tokenId = 0;
        nonfungiblePositionManager.safeTransferFrom(address(this), msg.sender, tokenId);
    }


    // calculates amount which needs to be payed to liquidate position - if it doesn't have enough value anymore - part is covered by reserves
    function _calculateLiquidation(uint debt, uint fullValue, uint collateralValue) internal returns (uint leftover, uint liquidatorCost, uint reserveCost) {

        uint MAX_LIQUIDATION_PENALTY_X32 = Q32 / 10; // 10%
        uint UNDERWATER_LIQUIDATION_PENALTY_X32 = Q32 / 20; // 5%

        // position value needed to pay debt at max penalty
        uint maxPenaltyValue = debt * (Q32 + MAX_LIQUIDATION_PENALTY_X32) / Q32;

        // position value when position started to be liquidatable
        uint startLiquidationValue = debt * fullValue / collateralValue;

        if (fullValue > maxPenaltyValue) {
            // calculate penalty and leftover
            uint penaltyFractionX96 = (Q96 - ((fullValue - maxPenaltyValue) * Q96 / (startLiquidationValue - maxPenaltyValue)));
            uint penaltyX32 = MAX_LIQUIDATION_PENALTY_X32 * penaltyFractionX96 / Q96;
            uint penaltyValue = fullValue * (Q32 - penaltyX32) / Q32;
            leftover = penaltyValue - debt;
            liquidatorCost = penaltyValue;
        } else {
            // position value needed to pay debt at underwater penalty
            uint underwaterPenaltyValue = debt * (Q32 + UNDERWATER_LIQUIDATION_PENALTY_X32) / Q32;

            // if position has enough value to pay penalty and no be underwater
            if (fullValue > underwaterPenaltyValue) {
                liquidatorCost = debt;
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
        if (collateralFactorX32 > MAX_COLLATERAL_FACTOR_X32) {
            revert CollateralFactorExceedsMax();
        }
        tokenConfigs[token] = TokenConfig(collateralFactorX32);
    }

    ////////////////// INTERNAL FUNCTIONS

    function _calculateTokenCollateralFactorX32(uint tokenId) internal returns (uint32) {
        (,,address token0,address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        uint32 factor0X32 = tokenConfigs[token0].collateralFactorX32;
        uint32 factor1X32 = tokenConfigs[token1].collateralFactorX32;
        return factor0X32 > factor1X32 ? factor1X32 : factor0X32;
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
            uint borrowRateX96 = interestRateModel.getBorrowRateX96(globalLendAmount, globalDebtAmount);
            uint interestX96 = (block.timestamp - lastInterestUpdate) * borrowRateX96;
            lastInterestTotalX96 += lastInterestTotalX96 * interestX96 / Q96;
            lastInterestUpdate = block.timestamp;

            uint debtGrowth = globalDebtAmount * interestX96 / Q96;
            globalDebtAmount += debtGrowth;
            globalLendAmount += debtGrowth * (Q32 - reserveFactorX32) / Q32;
            globalReserveAmount += debtGrowth * reserveFactorX32 / Q32;
        }
    }

    function _requireLoanIsHealthy(uint loanId) internal {
        (bool isHealthy,,) = _checkLoanIsHealthy(loanId);
        if (!isHealthy) {
            revert CollateralFail();
        }
    }

    function _checkLoanIsHealthy(uint loanId) internal returns (bool isHealty, uint fullValue, uint collateralValue) {
        // loan must be updated with interests at this point
        if (loans[loanId].lastInterestUpdate != block.timestamp) {
            revert InterestNotUpdated();
        }

        fullValue = oracle.getValue(loans[loanId].tokenId, address(lendToken));
        collateralValue = loans[loanId].collateralFactorX32 * fullValue / Q32;
        
        isHealty = collateralValue >= loans[loanId].amount;
    }

    function _calculateInterest(uint amount, uint lastUpdate, uint lastTotalX96, bool isBorrower) internal returns (uint) {
        return amount * (block.timestamp - lastUpdate) * (lastInterestTotalX96 - lastTotalX96) / Q96 * (isBorrower ? Q32 : Q32 - reserveFactorX32) / Q32;
    }
}