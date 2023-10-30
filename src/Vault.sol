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

import "forge-std/console.sol";

import "./V3Oracle.sol";

interface IInterestRateModel {
    // gets interest rate per second per unit of debt x96
    function getBorrowRatePerSecondX96(uint cash, uint debt) external view returns (uint256 result);
}

contract InterestRateModel is Ownable, IInterestRateModel {

    uint constant Q96 = 2 ** 96;
    uint constant YEAR_SECS = 31556925216; // taking into account leap years

    // all values are multiplied by Q96
    uint public multiplierPerSecond;
    uint public baseRatePerSecond;
    uint public jumpMultiplierPerSecond;
    uint public kink;

    constructor(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) {
        baseRatePerSecond = baseRatePerYear / YEAR_SECS;
        multiplierPerSecond = multiplierPerYear / YEAR_SECS;
        jumpMultiplierPerSecond = jumpMultiplierPerYear / YEAR_SECS;
        kink = kink_;
    }

    function getUtilizationRateX96(uint cash, uint debt) public pure returns (uint) {
        if (debt == 0) {
            return 0;
        }
        return debt * Q96 / (cash + debt);
    }

    function getBorrowRatePerSecondX96(uint cash, uint debt) override external view returns (uint) {
        uint utilizationRate = getUtilizationRateX96(cash, debt);

        if (utilizationRate <= kink) {
            return (utilizationRate * multiplierPerSecond / Q96) + baseRatePerSecond;
        } else {
            uint normalRate = (kink * multiplierPerSecond / Q96) + baseRatePerSecond;
            uint excessUtil = utilizationRate - kink;
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

    uint public constant MAX_COLLATERAL_FACTOR_X32 = Q32 * 90 / 100; // 90%
    uint public constant MAX_LIQUIDATION_PENALTY_X32 = Q32 / 10; // 10%
    uint public constant UNDERWATER_LIQUIDATION_PENALTY_X32 = Q32 / 20; // 5%

    /// @notice Uniswap v3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice Uniswap v3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice Token which is lent in this vault
    IERC20 public immutable lendToken;

    error Reentrancy();
    error NotOwner();
    error WrongContract();
    error CollateralFail();
    error GlobalBorrowLimit();
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
    uint32 public reserveFactorX32;

    // percentage of lend amount which needs to be in reserves before withdrawn
    uint32 public reserveProtectionFactorX32;


    uint public globalDebtAmountX96;
    uint public globalLendAmountX96;
    uint public globalReserveAmountX96;

    uint public globalBorrowLimitX96;
    uint public globalLendLimitX96;

    uint public lastInterestUpdate;

    uint public lastInterestTotalLendX96 = Q96;
    uint public lastInterestTotalDebtX96 = Q96;

    struct Lender {
        uint256 lastInterestTotalX96;
        uint256 amountX96;
    }
    mapping(address => Lender) public lenders;

    struct Loan {
        address owner;
        uint lastInterestTotalX96;
        uint amountX96;
        uint32 collateralFactorX32; // assigned at loan creation
    }

    mapping(uint => Loan) public loans; // tokenID -> loan mapping

    // contracts allowed to transform positions
    uint transformedTokenId; // transient (when available)
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

        if (transformedTokenId == 0) {
            _updateGlobalInterest();

            loans[tokenId] = Loan(owner, lastInterestTotalDebtX96, 0, _calculateTokenCollateralFactorX32(tokenId));

            // direct borrow if requested
            if (amount > 0) {
                _borrow(tokenId, amount, false, true);
            }
        } else {
            // if in transform mode - current token is replaced
            if (tokenId != transformedTokenId) {

                loans[tokenId] = loans[transformedTokenId];
                loans[tokenId].collateralFactorX32 = _calculateTokenCollateralFactorX32(tokenId);

                delete loans[transformedTokenId];
                transformedTokenId = tokenId;
            }
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    // method which allows a contract to transform a loan by borrowing and adding collateral in an atomic fashion
    function transform(uint tokenId, address transformer, bytes calldata data) external {
        if (!transformerAllowList[transformer]) {
            revert TransformerNotAllowed();
        }
        if (transformedTokenId > 0) {
            revert Reentrancy();
        }
        transformedTokenId = tokenId;

        _updateGlobalInterest();
        _updateLoanInterest(tokenId);

        Loan storage loan = loans[tokenId];
        // TODO add mechanism to allow other addresses (e.g. auto range to call the transform method)
        if (loan.owner != msg.sender) {
            revert NotOwner();
        }

        // give access to transformer
        nonfungiblePositionManager.approve(transformer, tokenId);

        (bool success,) = transformer.call(data);
        if (!success) {
            revert TransformFailed();
        }
        
        // check owner not changed (NEEDED beacuse approvalForAll could be set which would fake complete ownership)
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != address(this)) {
            revert NotOwner();
        }

        // remove access for msg.sender
        nonfungiblePositionManager.approve(address(0), tokenId);

        _requireLoanIsHealthy(tokenId, loan.amountX96);

        transformedTokenId = 0;
    }

    function borrow(uint tokenId, uint amount) external {

        bool isTransformMode = transformedTokenId > 0 && transformedTokenId == tokenId && transformerAllowList[msg.sender];

        // if not in transform mode - caller must be owner
        if (!isTransformMode) {
            _borrow(tokenId, amount, true, true);
        } else {
            _borrow(tokenId, amount, false, false);
        }
    }

    function _borrow(uint tokenId, uint amount, bool doOwnerCheck, bool doHealthCheck) internal {

        _updateGlobalInterest();
        _updateLoanInterest(tokenId);

        Loan storage loan = loans[tokenId];
        if (doOwnerCheck && loan.owner != msg.sender) {
            revert NotOwner();
        }

        loan.amountX96 += amount * Q96;
        globalDebtAmountX96 += amount * Q96;

        if (globalDebtAmountX96 > globalBorrowLimitX96) {
            revert GlobalBorrowLimit();
        }

        // fails if not enough lendToken available
        // if called from transform mode - send funds to transformer contract
        lendToken.transfer(!doHealthCheck ? msg.sender : loan.owner, amount);

        // only check health if not in transform mode
        if (doHealthCheck) {
            _requireLoanIsHealthy(tokenId, loan.amountX96);
        }
    }

    function lendInfo(address account) external view returns (uint amount) {
        uint currentInterestTotalX96;
        (,currentInterestTotalX96,,,) = _calculateGlobalInterest();
        uint amountX96 = _addInterest(lenders[account].amountX96, lenders[account].lastInterestTotalX96, currentInterestTotalX96);
        amount = amountX96 / Q96;
    }

    function loanInfo(uint tokenId) external view returns (uint debt, uint fullValue, uint collateralValue)  {
        uint currentInterestTotalX96;
        (currentInterestTotalX96,,,,) = _calculateGlobalInterest();
        uint debtX96 = _addInterest(loans[tokenId].amountX96, loans[tokenId].lastInterestTotalX96, currentInterestTotalX96);
        (, uint fullValueX96, uint collateralValueX96) = _checkLoanIsHealthy(tokenId, debtX96);

        fullValue = fullValueX96 / Q96;
        collateralValue = collateralValueX96 / Q96;
        debt = _roundUpX96(debtX96) / Q96;
    }

    function repay(uint tokenId, uint amount) external {

        uint amountX96 = amount * Q96;

        _updateGlobalInterest();
        _updateLoanInterest(tokenId);

        Loan storage loan = loans[tokenId];

        if (amountX96 > loan.amountX96) {

            amountX96 = loan.amountX96;
            amount = _roundUpX96(amountX96) / Q96;

            // add rounding error to reserves
            globalReserveAmountX96 += amount * Q96 - amountX96;
        }


        if (amount > 0) {
            lendToken.transferFrom(msg.sender, address(this), amount);
        }

        loan.amountX96 -= amountX96;
        globalDebtAmountX96 -= amountX96;

        // if fully repayed
        if (loan.amountX96 == 0) {
            address owner = loan.owner;
            delete loans[tokenId];
            nonfungiblePositionManager.safeTransferFrom(address(this), owner, tokenId);
        }
    }

    function deposit(uint256 amount) external {
        
        uint amountX96 = amount * Q96;

        _updateGlobalInterest();
        _updateLenderInterest(msg.sender);
        
        lendToken.transferFrom(msg.sender, address(this), amount);

        lenders[msg.sender].amountX96 += amountX96;
        globalLendAmountX96 += amountX96;

        if (globalLendAmountX96 > globalLendLimitX96) {
            revert GlobalLendLimit();
        }
    }

    function withdraw(uint256 amount) external {
        
        uint amountX96 = amount * Q96;

        _updateGlobalInterest();
        _updateLenderInterest(msg.sender);
        
        if (amountX96 > lenders[msg.sender].amountX96) {
            amountX96 = lenders[msg.sender].amountX96;
            amount = amountX96 / Q96;

            // add rounding error to reserves
            globalReserveAmountX96 += amountX96 - amount * Q96;
        }

        uint availableX96 = _getAvailableBalanceX96();
        if (availableX96 < amountX96) {
            revert InsufficientLiquidity();
        }

        lenders[msg.sender].amountX96 -= amountX96;
        globalLendAmountX96 -= amountX96;

        lendToken.transfer(msg.sender, amount);
    }

    // function to liquidate position - needed lendtokens depending on current price
    function liquidate(uint tokenId) external {

        // liquidation is not allowed during transformer mode
        if (transformedTokenId > 0) {
            revert TransformerNotAllowed();
        }

        _updateGlobalInterest();
        _updateLoanInterest(tokenId);

        uint debtX96 = loans[tokenId].amountX96;

        (bool isHealthy, uint fullValueX96, uint collateralValueX96) = _checkLoanIsHealthy(tokenId, debtX96);
        if (isHealthy) {
            revert NotLiquidatable();
        }

        (uint leftoverX96, uint liquidatorCostX96, uint reserveCostX96) = _calculateLiquidation(debtX96, fullValueX96, collateralValueX96);

        // take value from liquidator (rounded up)
        uint liquidatorCost = _roundUpX96(liquidatorCostX96) / Q96;
        lendToken.transferFrom(msg.sender, address(this), liquidatorCost);

        // add rounding error to reserves
        globalReserveAmountX96 += liquidatorCost * Q96 - liquidatorCostX96;

        // send leftover to borrower if any
        if (leftoverX96 > 0) {
            uint leftover = leftoverX96 / Q96; // rounded down
            lendToken.transfer(loans[tokenId].owner, leftover);

            // add rounding error to reserves
            globalReserveAmountX96 += leftoverX96 - leftover * Q96;
        }
        
        // take remaining amount from reserves - if not enough - democratize debt
        if (reserveCostX96 > 0) {
            if (reserveCostX96 <= globalReserveAmountX96) {
                globalReserveAmountX96 -= reserveCostX96;
            } else {
                uint missingX96 = reserveCostX96 - globalReserveAmountX96;
                globalReserveAmountX96 = 0;

                // TODO verify math...
                // this lines distribute missing amount and remove it from all lent amount proportionally
                lastInterestTotalLendX96 = (globalLendAmountX96 - missingX96) * lastInterestTotalLendX96 / globalLendAmountX96;
                globalLendAmountX96 -= missingX96;
            }
        }

        // disarm loan and send collateral to liquidator
        Loan memory loan = loans[tokenId];
        globalDebtAmountX96 -= loan.amountX96;
        delete loans[tokenId];
        nonfungiblePositionManager.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    // checks how much balance is available - excluding reserves
    function _getAvailableBalanceX96() internal view returns (uint) {
        uint balance = lendToken.balanceOf(address(this));
        uint balanceX96 = balance * Q96;
        return balanceX96 > globalReserveAmountX96 ? balanceX96 - globalReserveAmountX96 : 0;
    }

    // calculates amount which needs to be payed to liquidate position
    //  if position is too valuable - leftover from liquidation is sent to position owner
    //  if position is not valuable enough - missing part is covered by reserves - if not enough reserves - collectively by other borrowers
    function _calculateLiquidation(uint debtX96, uint fullValueX96, uint collateralValueX96) internal pure returns (uint leftoverX96, uint liquidatorCostX96, uint reserveCostX96) {

        // position value needed to pay debt at max penalty
        uint maxPenaltyValueX96 = debtX96 * (Q32 + MAX_LIQUIDATION_PENALTY_X32) / Q32;

        // position value when position started to be liquidatable
        uint startLiquidationValueX96 = debtX96 * fullValueX96 / collateralValueX96;

        if (fullValueX96 > maxPenaltyValueX96) {
            // calculate penalty and leftover
            uint penaltyFractionX96 = (Q96 - ((fullValueX96 - maxPenaltyValueX96) * Q96 / (startLiquidationValueX96 - maxPenaltyValueX96)));
            uint penaltyX32 = MAX_LIQUIDATION_PENALTY_X32 * penaltyFractionX96 / Q96;
            uint penaltyValueX96 = fullValueX96 * (Q32 - penaltyX32) / Q32;
            leftoverX96 = penaltyValueX96 - debtX96;
            liquidatorCostX96 = penaltyValueX96;
        } else {
            // position value needed to pay debt at underwater penalty
            uint underwaterPenaltyValueX96 = debtX96 * (Q32 + UNDERWATER_LIQUIDATION_PENALTY_X32) / Q32;

            // if position has enough value to pay penalty and no be underwater
            if (fullValueX96 > underwaterPenaltyValueX96) {
                liquidatorCostX96 = debtX96;
            } else {
                uint penaltyValueX96 = fullValueX96 * (Q32 - UNDERWATER_LIQUIDATION_PENALTY_X32) / Q32;
                liquidatorCostX96 = penaltyValueX96;
                reserveCostX96 = debtX96 - penaltyValueX96;
            }
        }
    }


    ////////////////// ADMIN FUNCTIONS only callable by owner

    // function to withdraw protocol reserves 
    // only allows to withdraw excess reserves (> globalLendAmount * reserveProtectionFactor)
    function withdrawReserves(uint256 amount, address account) external onlyOwner {
        
        uint amountX96 = amount * Q96;

        _updateGlobalInterest();
       
        uint protectedX96 = globalLendAmountX96 * reserveProtectionFactorX32 / Q32;
        uint unprotectedX96 = globalReserveAmountX96 > protectedX96 ? globalReserveAmountX96 - protectedX96 : 0;
        uint balance = lendToken.balanceOf(address(this));
        uint balanceX96 = balance * Q96;
        uint availableX96 = balanceX96 > unprotectedX96 ? unprotectedX96 : balanceX96;

        if (amountX96 > availableX96) {
            amountX96 = availableX96;
            amount = amountX96 / Q96;
        }

        if (amount > 0) {
            globalReserveAmountX96 -= amount * Q96; // only remove exact amount from reserves
            lendToken.transfer(account, amount);
        }
    }

    // function to configure transformer contract 
    function setTransformer(address transformer, bool active) external onlyOwner {
        transformerAllowList[transformer] = active;
    }

    // function to set limits (this doesnt affect existing loans)
    function setLimits(uint _globalLendLimit, uint _globalBorrowLimit) external onlyOwner {
        globalLendLimitX96 = _globalLendLimit * Q96;
        globalBorrowLimitX96 = _globalBorrowLimit  * Q96;
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
    function _updateLoanInterest(uint tokenId) internal {
        Loan storage loan = loans[tokenId];
        if (lastInterestTotalDebtX96 != loan.lastInterestTotalX96) {
            loan.amountX96 = _addInterest(loan.amountX96, loan.lastInterestTotalX96, lastInterestTotalDebtX96);
            loan.lastInterestTotalX96 = lastInterestTotalDebtX96;
        }
    }

    function _updateLenderInterest(address lenderAddress) internal {
        Lender storage lender = lenders[lenderAddress];

        if (lastInterestTotalLendX96 != lender.lastInterestTotalX96) {
            lender.amountX96 += _addInterest(lender.amountX96, lender.lastInterestTotalX96, lastInterestTotalLendX96);
            lender.lastInterestTotalX96 = lastInterestTotalLendX96;
        }
    }

    function _updateGlobalInterest() internal {
        if (block.timestamp > lastInterestUpdate) {
            (lastInterestTotalDebtX96, lastInterestTotalLendX96, globalDebtAmountX96, globalLendAmountX96, globalReserveAmountX96) = _calculateGlobalInterest();
            lastInterestUpdate = block.timestamp;
        }
    }

    function _calculateGlobalInterest() internal view returns (uint interestTotalDebtX96, uint interestTotalLendX96, uint newDebtX96, uint newLendX96, uint newReservesX96) {
        uint balanceX96 = _getAvailableBalanceX96();
        uint borrowRateX96 = interestRateModel.getBorrowRatePerSecondX96(balanceX96, globalDebtAmountX96);

        // always growing or equal
        interestTotalDebtX96 = lastInterestTotalDebtX96 + lastInterestTotalDebtX96 * (block.timestamp - lastInterestUpdate) * borrowRateX96 / Q96;
    
        newDebtX96 = globalDebtAmountX96 * interestTotalDebtX96 / lastInterestTotalDebtX96;

        uint debtGrowthX96 = newDebtX96 - globalDebtAmountX96;
        uint lendGrowthX96 = debtGrowthX96 * (Q32 - reserveFactorX32) / Q32;

        newLendX96 = globalLendAmountX96 + lendGrowthX96;
        newReservesX96 = globalReserveAmountX96 + (debtGrowthX96 - lendGrowthX96);

        interestTotalLendX96 = lastInterestTotalLendX96 + (globalLendAmountX96 > 0 ? lastInterestTotalLendX96 * lendGrowthX96 / globalLendAmountX96 : 0);
    }

    function _requireLoanIsHealthy(uint tokenId, uint debtX96) internal view {
        (bool isHealthy,,) = _checkLoanIsHealthy(tokenId, debtX96);
        if (!isHealthy) {
            revert CollateralFail();
        }
    }

    function _checkLoanIsHealthy(uint tokenId, uint debtX96) internal view returns (bool isHealty, uint fullValueX96, uint collateralValueX96) {
        fullValueX96 = oracle.getValue(tokenId, address(lendToken)) * Q96;
        collateralValueX96 = loans[tokenId].collateralFactorX32 * fullValueX96 / Q32;
        isHealty = collateralValueX96 >= debtX96;
    }

    // adds (in rare cases removes) interest which was accrued to amount
    function _addInterest(uint amountX96, uint lastTotalX96, uint currentTotalX96) internal pure returns (uint) {
        return lastTotalX96 == 0 ? amountX96 : amountX96 * currentTotalX96 / lastTotalX96;
    }

    function _roundUpX96(uint amountX96) internal pure returns (uint) {
        return amountX96 % Q96 > 0 ? amountX96 - (amountX96 % Q96) + Q96 : amountX96;
    }
}