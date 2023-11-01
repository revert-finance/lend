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
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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

/// @title Vault for token lending / borrowing using LP positions as collateral
contract Vault is ERC20, Ownable, IERC721Receiver {

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

    // all stored & internal amounts are multiplied by this multiplier to get increased precision for low precision tokens
    uint public immutable lendTokenMultiplier;

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
    uint32 public reserveFactorX32;

    // percentage of lend amount which needs to be in reserves before withdrawn
    uint32 public reserveProtectionFactorX32;

    // total of debt shares - increases when borrow - decreases when repay
    uint public debtSharesTotal;

    uint public lastExchangeRateUpdate;
    uint public lastDebtExchangeRateX96 = Q96;
    uint public lastLendExchangeRateX96 = Q96;

    uint public globalDebtLimit;
    uint public globalLendLimit;

    // lender balances are handled with ERC-20 mint/burn

    // loans are handled with this struct
    struct Loan {
        uint debtShares;
        address owner;
        uint32 collateralFactorX32; // assigned at loan creation
    }
    mapping(uint => Loan) public loans; // tokenID -> loan mapping

    uint transformedTokenId; // transient (when available)
    mapping(address => bool) transformerAllowList; // contracts allowed to transform positions
    mapping(address => mapping(address => bool)) transformApprovals; // owners permissions for other addresses to call transform on owners behalf

    constructor(string memory name, string memory symbol, INonfungiblePositionManager _nonfungiblePositionManager, IERC20 _lendToken, IInterestRateModel _interestRateModel, IV3Oracle _oracle) ERC20(name, symbol) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        lendToken = _lendToken;
        uint8 decimals = IERC20Metadata(address(_lendToken)).decimals();
        lendTokenMultiplier = decimals >= 18 ? 1 : 10 ** (18 - decimals);
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

        if (transformedTokenId == 0) {
            _updateGlobalInterest();

            // parameters sent define owner, and initial borrow amount
            (address owner, uint amount) = abi.decode(data, (address, uint));

            loans[tokenId] = Loan(0, owner, _calculateTokenCollateralFactorX32(tokenId));

            // direct borrow if requested
            if (amount > 0) {
                _borrow(tokenId, amount, false, true);
            }
        } else {
            // if in transform mode - current token is replaced
            if (tokenId != transformedTokenId) {

                // loan is migrated to new token
                loans[tokenId] = loans[transformedTokenId];
                loans[tokenId].collateralFactorX32 = _calculateTokenCollateralFactorX32(tokenId);

                // old load is removed
                delete loans[transformedTokenId];
                transformedTokenId = tokenId;
            }
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    // allows another address to call transform on behalf of owner
    function approveTransform(address target, bool active) external {
        transformApprovals[msg.sender][target] = active;
    }

    // method which allows a contract to transform a loan by borrowing and adding collateral in an atomic fashion
    function transform(uint tokenId, address transformer, bytes calldata data) external returns (uint) {
        if (!transformerAllowList[transformer]) {
            revert TransformerNotAllowed();
        }
        if (transformedTokenId > 0) {
            revert Reentrancy();
        }
        transformedTokenId = tokenId;

        (uint newDebtExchangeRateX96,) = _updateGlobalInterest();

        address loanOwner = loans[tokenId].owner;

        // TODO add mechanism to allow other addresses (e.g. auto range to call the transform method)
        if (loanOwner != msg.sender && !transformApprovals[loanOwner][msg.sender]) {
            revert NotOwner();
        }

        // give access to transformer
        nonfungiblePositionManager.approve(transformer, tokenId);

        (bool success,) = transformer.call(data);
        if (!success) {
            revert TransformFailed();
        }
        
        // may have changed in the meantime
        tokenId = transformedTokenId;

        // check owner not changed (NEEDED beacuse approvalForAll could be set which would fake complete ownership)
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != address(this)) {
            revert NotOwner();
        }

        // remove access for msg.sender
        nonfungiblePositionManager.approve(address(0), tokenId);

        _requireLoanIsHealthy(tokenId, _convertSharesToTokens(loans[tokenId].debtShares, newDebtExchangeRateX96));

        transformedTokenId = 0;

        return tokenId;
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

        (uint newDebtExchangeRateX96, ) = _updateGlobalInterest();

        Loan storage loan = loans[tokenId];
        if (doOwnerCheck && loan.owner != msg.sender) {
            revert NotOwner();
        }

        uint internalAmount = _convertExternalToInternal(amount);
        uint newDebtShares = _convertTokensToShares(internalAmount, newDebtExchangeRateX96);

        loan.debtShares += newDebtShares;
        debtSharesTotal += newDebtShares;

        if (debtSharesTotal > _convertTokensToShares(globalDebtLimit, newDebtExchangeRateX96)) {
            revert GlobalDebtLimit();
        }

        // fails if not enough lendToken available
        // if called from transform mode - send funds to transformer contract
        lendToken.transfer(!doHealthCheck ? msg.sender : loan.owner, amount);

        // only check health if not in transform mode
        if (doHealthCheck) {
            uint debt = _convertSharesToTokens(loan.debtShares, newDebtExchangeRateX96);
            _requireLoanIsHealthy(tokenId, debt);
        }
    }

    function protocolInfo() external view returns (uint debt, uint lent, uint balance, uint available, uint reserves) {
        (uint newDebtExchangeRateX96, uint newLendExchangeRateX96) = _calculateGlobalInterest();
        (balance, available, reserves) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);

        console.log(balance, available, reserves);

        debt = _convertSharesToTokens(debtSharesTotal, newDebtExchangeRateX96);
        lent = _convertSharesToTokens(totalSupply(), newLendExchangeRateX96);

        debt = _convertInternalToExternal(debt, true);
        lent = _convertInternalToExternal(lent, false);

        balance = _convertInternalToExternal(balance, false);
        available = _convertInternalToExternal(available, false);
        reserves = _convertInternalToExternal(reserves, false);
    }

    function lendInfo(address account) external view returns (uint amount) {
        (, uint newLendExchangeRateX96) = _calculateGlobalInterest();
        amount = _convertSharesToTokens(balanceOf(account), newLendExchangeRateX96);
        amount = _convertInternalToExternal(amount, false);
    }

    function loanInfo(uint tokenId) external view returns (uint debt, uint fullValue, uint collateralValue, uint liquidationCost)  {
        (uint newDebtExchangeRateX96,) = _calculateGlobalInterest();
        uint debtInternal = _convertSharesToTokens(loans[tokenId].debtShares, newDebtExchangeRateX96);

        bool isHealthy;
        (isHealthy, fullValue, collateralValue) = _checkLoanIsHealthy(tokenId, debtInternal);

        if (!isHealthy) {
            (, liquidationCost,) = _calculateLiquidation(debtInternal, fullValue, collateralValue);
        }
        
        debt = _convertInternalToExternal(debtInternal, true);
        fullValue = _convertInternalToExternal(fullValue, false);
        collateralValue = _convertInternalToExternal(collateralValue, false);
        liquidationCost = _convertInternalToExternal(liquidationCost, true);
    }

    function repay(uint tokenId, uint amount) external {

        (uint newDebtExchangeRateX96,) = _updateGlobalInterest();

        Loan storage loan = loans[tokenId];

        uint debt = _convertSharesToTokens(loan.debtShares, newDebtExchangeRateX96);
        uint internalAmount = _convertExternalToInternal(amount);
        uint repayedDebtShares;

        if (internalAmount > debt) {
            // repay all
            amount = _convertInternalToExternal(debt, true);
            // rounding rest is implicitly added to reserves
            repayedDebtShares = loan.debtShares;
        } else {
            repayedDebtShares = _convertTokensToShares(internalAmount, newDebtExchangeRateX96);
        }

        if (amount > 0) {
            lendToken.transferFrom(msg.sender, address(this), amount);
        }

        loan.debtShares -= repayedDebtShares;
        debtSharesTotal -= repayedDebtShares;

        // if fully repayed
        if (loan.debtShares == 0) {
            address owner = loan.owner;
            delete loans[tokenId];
            nonfungiblePositionManager.safeTransferFrom(address(this), owner, tokenId);
        }
    }

    function deposit(uint256 amount) external {
        
        uint internalAmount = _convertExternalToInternal(amount);

        (, uint newLendExchangeRateX96) = _updateGlobalInterest();
        
        // pull lend tokens
        lendToken.transferFrom(msg.sender, address(this), amount);

        // mint corresponding amount to msg.sender
        uint sharesToMint = _convertTokensToShares(internalAmount, newLendExchangeRateX96);
        _mint(msg.sender, sharesToMint);

        if (totalSupply() > globalLendLimit) {
            revert GlobalLendLimit();
        }
    }

    // withdraws lent tokens. can be denominated in token or share amount
    function withdraw(uint256 amount, bool isShare) external {

        (uint newDebtExchangeRateX96,uint newLendExchangeRateX96) = _updateGlobalInterest();

        uint shareAmount;
        uint internalAmount;
        if (isShare) {
            shareAmount = amount;
            internalAmount = _convertSharesToTokens(shareAmount, newLendExchangeRateX96);
            amount = _convertInternalToExternal(internalAmount, false);
        } else {
            internalAmount = _convertExternalToInternal(amount);
            shareAmount = _convertTokensToShares(_convertExternalToInternal(amount), newLendExchangeRateX96);
        }        

        (,uint available,) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);
        if (available < internalAmount) {
            revert InsufficientLiquidity();
        }

        // fails if not enough shares
        _burn(msg.sender, shareAmount);

        // transfer lend token - after all checks done
        lendToken.transfer(msg.sender, amount);
    }

    // function to liquidate position - needed lendtokens depending on current price
    function liquidate(uint tokenId) external {

        // liquidation is not allowed during transformer mode
        if (transformedTokenId > 0) {
            revert TransformerNotAllowed();
        }

        (uint newDebtExchangeRateX96, uint newLendExchangeRateX96) = _updateGlobalInterest();

        uint debt = _convertSharesToTokens(loans[tokenId].debtShares, newDebtExchangeRateX96);

        (bool isHealthy, uint fullValue, uint collateralValue) = _checkLoanIsHealthy(tokenId, debt);
        if (isHealthy) {
            revert NotLiquidatable();
        }

        (uint leftover, uint liquidatorCost, uint reserveCost) = _calculateLiquidation(debt, fullValue, collateralValue);

        // take value from liquidator (rounded up)
        liquidatorCost = _convertInternalToExternal(liquidatorCost, true);
        lendToken.transferFrom(msg.sender, address(this), liquidatorCost);
        // rounding rest is implicitly added to reserves

        // send leftover to borrower if any
        if (leftover > 0) {
            leftover = _convertInternalToExternal(leftover, false);
            lendToken.transfer(loans[tokenId].owner, leftover);
            // rounding rest is implicitly added to reserves
        }
        
        // take remaining amount from reserves
        if (reserveCost > 0) {
            (,,uint reserves) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);

            // if not enough - democratize debt
            if (reserveCost > reserves) {
                uint missing = reserveCost - reserves;

                uint totalLent = _convertSharesToTokens(totalSupply(), newLendExchangeRateX96);

                // this lines distribute missing amount and remove it from all lent amount proportionally
                lastLendExchangeRateX96 = (totalLent - missing) * newLendExchangeRateX96 / totalLent;
            }
        }

        // disarm loan and send collateral to liquidator
        debtSharesTotal -= loans[tokenId].debtShares;
        delete loans[tokenId];
        nonfungiblePositionManager.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    // checks how much balance is available - excluding reserves
    function _getAvailableBalance(uint debtExchangeRateX96, uint lendExchangeRateX96) internal view returns (uint balance, uint available, uint reserves) {

        balance = _convertExternalToInternal(lendToken.balanceOf(address(this)));
        uint debt = _convertSharesToTokens(debtSharesTotal, debtExchangeRateX96);
        uint lent = _convertSharesToTokens(totalSupply(), lendExchangeRateX96);

        reserves = balance + debt - lent;
        available = balance > reserves ? balance - reserves : 0;
    }

    // calculates amount which needs to be payed to liquidate position
    //  if position is too valuable - leftover from liquidation is sent to position owner
    //  if position is not valuable enough - missing part is covered by reserves - if not enough reserves - collectively by other borrowers
    function _calculateLiquidation(uint debt, uint fullValue, uint collateralValue) internal pure returns (uint leftover, uint liquidatorCost, uint reserveCost) {

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
        
        (uint newDebtExchangeRateX96, uint newLendExchangeRateX96) = _updateGlobalInterest();
       
        uint protected = _convertSharesToTokens(totalSupply(), newLendExchangeRateX96) * reserveProtectionFactorX32 / Q32;
        (uint balance,,uint reserves) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);
        uint unprotected = reserves > protected ? reserves - protected : 0;
        uint available = balance > unprotected ? unprotected : balance;

        uint internalAmount = _convertExternalToInternal(amount);
        if (internalAmount > available) {
            revert InsufficientLiquidity();
        }

        if (amount > 0) {
            lendToken.transfer(account, amount);
        }
    }

    // function to configure transformer contract 
    function setTransformer(address transformer, bool active) external onlyOwner {
        transformerAllowList[transformer] = active;
    }

    // function to set limits (this doesnt affect existing loans)
    function setLimits(uint _globalLendLimit, uint _globalDebtLimit) external onlyOwner {
        globalLendLimit = _convertExternalToInternal(_globalLendLimit);
        globalDebtLimit = _convertExternalToInternal(_globalDebtLimit);
    }

    // function to set reserve factor - percentage difference between Debting and lending interest
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

    function _calculateTokenCollateralFactorX32(uint tokenId) internal view returns (uint32) {
        (,,address token0,address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        uint32 factor0X32 = tokenConfigs[token0].collateralFactorX32;
        uint32 factor1X32 = tokenConfigs[token1].collateralFactorX32;
        return factor0X32 > factor1X32 ? factor1X32 : factor0X32;
    }

    function _updateGlobalInterest() internal returns (uint newDebtExchangeRateX96, uint newLendExchangeRateX96) {
        if (block.timestamp > lastExchangeRateUpdate) {
            (newDebtExchangeRateX96, newLendExchangeRateX96) = _calculateGlobalInterest();
            lastDebtExchangeRateX96 = newDebtExchangeRateX96;
            lastLendExchangeRateX96 = newLendExchangeRateX96;
            lastExchangeRateUpdate = block.timestamp;
        } else {
            newDebtExchangeRateX96 = lastDebtExchangeRateX96;
            newLendExchangeRateX96 = lastLendExchangeRateX96;
        }
    }

    function _calculateGlobalInterest() internal view returns (uint newDebtExchangeRateX96, uint newLendExchangeRateX96) {

        uint oldDebtExchangeRateX96 = lastDebtExchangeRateX96;
        uint oldLendExchangeRateX96 = lastLendExchangeRateX96;

        (,uint available, ) = _getAvailableBalance(oldDebtExchangeRateX96, oldLendExchangeRateX96);


        uint oldDebt = _convertSharesToTokens(debtSharesTotal, oldDebtExchangeRateX96);
        uint oldLend = _convertSharesToTokens(totalSupply(), oldLendExchangeRateX96);

        uint borrowRateX96 = interestRateModel.getBorrowRatePerSecondX96(available, oldDebt);

        // always growing or equal
        newDebtExchangeRateX96 = oldDebtExchangeRateX96 + oldDebtExchangeRateX96 * (block.timestamp - lastExchangeRateUpdate) * borrowRateX96 / Q96;

        uint newDebt = _convertSharesToTokens(debtSharesTotal, newDebtExchangeRateX96);

        uint debtGrowth = newDebt - oldDebt;
        uint lendGrowth = debtGrowth * (Q32 - reserveFactorX32) / Q32;

        newLendExchangeRateX96 = oldLendExchangeRateX96 + (oldLend > 0 ? oldLendExchangeRateX96 * lendGrowth / oldLend : 0);
    }

    function _requireLoanIsHealthy(uint tokenId, uint debt) internal view {
        (bool isHealthy,,) = _checkLoanIsHealthy(tokenId, debt);
        if (!isHealthy) {
            revert CollateralFail();
        }
    }

    function _checkLoanIsHealthy(uint tokenId, uint debt) internal view returns (bool isHealty, uint fullValue, uint collateralValue) {
        uint oracleValue = oracle.getValue(tokenId, address(lendToken));
        fullValue = _convertExternalToInternal(oracleValue);
        collateralValue = loans[tokenId].collateralFactorX32 * fullValue / Q32;
        isHealty = collateralValue >= debt;
    }

    function _roundUp(uint amount) internal view returns (uint) {
        return amount % lendTokenMultiplier > 0 ? amount - (amount % lendTokenMultiplier) + lendTokenMultiplier : amount;
    }

    function _convertTokensToShares(uint amount, uint exchangeRateX96) internal pure returns(uint) {
        return amount * Q96 / exchangeRateX96;
    }

    function _convertSharesToTokens(uint shares, uint exchangeRateX96) internal pure returns(uint) {
        return shares * exchangeRateX96 / Q96;
    }

    function _convertInternalToExternal(uint amount, bool roundUp) internal view returns(uint) {
        return roundUp ? _roundUp(amount) / lendTokenMultiplier : amount / lendTokenMultiplier;
    }

    function _convertExternalToInternal(uint amount) internal view returns(uint) {
        return amount * lendTokenMultiplier;
    }
}