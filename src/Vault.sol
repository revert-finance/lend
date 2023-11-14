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
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IV3Oracle.sol";
import "./interfaces/IInterestRateModel.sol";

/// @title Vault for token lending / borrowing using LP positions as collateral
contract Vault is IVault, ERC20, Ownable, IERC721Receiver {

    uint constant Q32 = 2 ** 32;
    uint constant Q96 = 2 ** 96;

    uint public constant MAX_COLLATERAL_FACTOR_X32 = Q32 * 90 / 100; // 90%
    uint public constant MAX_LIQUIDATION_PENALTY_X32 = Q32 / 10; // 10%
    uint public constant UNDERWATER_LIQUIDATION_PENALTY_X32 = Q32 / 20; // 5% TODO should be the same as max liquidiation penalty?

    /// @notice Uniswap v3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice Uniswap v3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice Token which is lent in this vault
    address public immutable override lendToken;

    // all stored & internal amounts are multiplied by this multiplier to get increased precision for low precision tokens
    uint public immutable lendTokenMultiplier;

    // interest rate model - immutable but configurable
    IInterestRateModel immutable public interestRateModel;

    // oracle - immutable but configurable
    IV3Oracle immutable public oracle;


    // events
    event ExchangeRateUpdate(uint debtExchangeRateX96, uint lendExchangeRateX96);
    event Deposit(address indexed account, uint amount, uint shares);
    event Withdraw(address indexed account, uint amount, uint shares);

    event WithdrawCollateral(uint indexed tokenId, address indexed owner, address recipient, uint amount0, uint amount1);
    event Borrow(uint indexed tokenId, address indexed owner, uint amount, uint shares);
    event Repay(uint indexed tokenId, address indexed repayer, address indexed owner, uint amount, uint shares);
    event Liquidate(uint indexed tokenId, address indexed liquidator, address indexed owner, uint value, uint cost, uint leftover, uint reserve, uint missing); // shows exactly how liquidation amounts were divided

    // admin events
    event WithdrawReserves(uint256 amount, address account);
    event SetTransformer(address transformer, bool active);
    event SetLimits(uint globalLendLimit, uint globalDebtLimit);
    event SetReserveFactor(uint32 reserveFactorX32);
    event SetReserveProtectionFactor(uint32 reserveProtectionFactorX32);
    event SetTokenConfig(address token, uint32 collateralFactorX32, uint216 collateralValueLimit);

    // errors
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
    error RepayExceedsDebt();
    error CollateralFactorExceedsMax();
    error CollateralValueLimit();

    struct TokenConfig {
        uint32 collateralFactorX32; // how much this token is valued as collateral
        uint216 collateralValueLimit; // how much lendtoken equivalent may be lent out given this collateral
        uint collateralTotal; // how much of this collateral token was used (at creation) of loans
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

        // how much collateral of each token was reserved for this loan (at creation)
        uint collateral0;
        uint collateral1;
    }
    mapping(uint => Loan) public loans; // tokenID -> loan mapping

    uint transformedTokenId; // transient (when available)
    mapping(address => bool) transformerAllowList; // contracts allowed to transform positions
    mapping(address => mapping(address => bool)) transformApprovals; // owners permissions for other addresses to call transform on owners behalf

    constructor(string memory name, string memory symbol, INonfungiblePositionManager _nonfungiblePositionManager, address _lendToken, IInterestRateModel _interestRateModel, IV3Oracle _oracle) ERC20(name, symbol) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        lendToken = _lendToken;
        uint8 decimals = IERC20Metadata(address(_lendToken)).decimals();
        lendTokenMultiplier = decimals >= 18 ? 1 : 10 ** (18 - decimals);
        interestRateModel = _interestRateModel;
        oracle = _oracle;
    }

    ////////////////// EXTERNAL VIEW FUNCTIONS

    function protocolInfo() external view returns (uint debt, uint lent, uint balance, uint available, uint reserves) {
        (uint newDebtExchangeRateX96, uint newLendExchangeRateX96) = _calculateGlobalInterest();
        (balance, available, reserves) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);

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
        (isHealthy, fullValue, collateralValue,,) = _checkLoanIsHealthy(tokenId, debtInternal);

        if (!isHealthy) {
            (,liquidationCost,) = _calculateLiquidation(debtInternal, fullValue, collateralValue);
        }
        
        debt = _convertInternalToExternal(debtInternal, true);
        fullValue = _convertInternalToExternal(fullValue, false);
        collateralValue = _convertInternalToExternal(collateralValue, false);
        liquidationCost = _convertInternalToExternal(liquidationCost, true);
    }

    function ownerOf(uint tokenId) override external view returns (address) {
        return loans[tokenId].owner;
    }

    ////////////////// EXTERNAL FUNCTIONS

    function create(uint256 tokenId, CreateParams calldata params) external override {
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(params));
    }

    function createWithPermit(uint256 tokenId, CreateParams calldata params, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external override {
        nonfungiblePositionManager.permit(address(this), tokenId, deadline, v, r, s);
        nonfungiblePositionManager.safeTransferFrom(params.owner, address(this), tokenId, abi.encode(params));
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        // only Uniswap v3 NFTs allowed - sent from other contract
        if (msg.sender != address(nonfungiblePositionManager) || from == address(this)) {
            revert WrongContract();
        }

        if (transformedTokenId == 0) {
            _updateGlobalInterest();

            // parameters sent define owner, and initial borrow amount
            CreateParams memory params = abi.decode(data, (CreateParams));

            loans[tokenId] = Loan(0, params.owner, _calculateTokenCollateralFactorX32(tokenId), 0, 0);

            // direct borrow if requested
            if (params.amount > 0) {
                this.borrow(tokenId, params.amount);
            }

            // direct transform if requested
            if (params.transformer != address(0)) {
                this.transform(tokenId, params.transformer, params.transformerData);
            }
        } else {

            uint oldTokenId = transformedTokenId;

            // if in transform mode - and a new position is sent - current position is replaced and returned
            if (tokenId != oldTokenId) {

                // set transformed token to new one
                transformedTokenId = tokenId;

                // copy debt to new token
                loans[tokenId].debtShares = loans[oldTokenId].debtShares;
                loans[tokenId].collateralFactorX32 = _calculateTokenCollateralFactorX32(tokenId);

                // clears data of old loan
                _cleanupLoan(oldTokenId, loans[oldTokenId].owner);
            }
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    // allows another address to call transform on behalf of owner
    function approveTransform(address target, bool active) external override {
        transformApprovals[msg.sender][target] = active;
    }

    // method which allows a contract to transform a loan by borrowing and adding collateral in an atomic fashion
    function transform(uint tokenId, address transformer, bytes calldata data) external override returns (uint) {
        if (!transformerAllowList[transformer]) {
            revert TransformerNotAllowed();
        }
        if (transformedTokenId > 0) {
            revert Reentrancy();
        }
        transformedTokenId = tokenId;

        (uint newDebtExchangeRateX96,) = _updateGlobalInterest();

        address loanOwner = loans[tokenId].owner;

        // only the owner of the loan, the vault itself or any approved caller can call this
        if (loanOwner != msg.sender && address(this) != msg.sender && !transformApprovals[loanOwner][msg.sender]) {
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

        _requireLoanIsHealthyAndCollateralValid(tokenId, _convertSharesToTokens(loans[tokenId].debtShares, newDebtExchangeRateX96));

        transformedTokenId = 0;

        return tokenId;
    }


    function borrow(uint tokenId, uint amount) external override {

        bool isTransformMode = transformedTokenId > 0 && transformedTokenId == tokenId && transformerAllowList[msg.sender];

        (uint newDebtExchangeRateX96, ) = _updateGlobalInterest();

        Loan storage loan = loans[tokenId];

        // if not in transfer mode - must be called from owner or 
        if (!isTransformMode && loan.owner != msg.sender && address(this) != msg.sender) {
            revert NotOwner();
        }

        uint internalAmount = _convertExternalToInternal(amount);
        uint newDebtShares = _convertTokensToShares(internalAmount, newDebtExchangeRateX96);

        loan.debtShares += newDebtShares;
        debtSharesTotal += newDebtShares;

        if (debtSharesTotal > _convertTokensToShares(globalDebtLimit, newDebtExchangeRateX96)) {
            revert GlobalDebtLimit();
        }

        uint debt = _convertSharesToTokens(loan.debtShares, newDebtExchangeRateX96);

        // only does check health here if not in transform mode
        if (!isTransformMode) {
            _requireLoanIsHealthyAndCollateralValid(tokenId, debt);
        }

        // fails if not enough lendToken available
        // if called from transform mode - send funds to transformer contract
        IERC20(lendToken).transfer(isTransformMode ? msg.sender : loan.owner, amount);

        emit Borrow(tokenId, loan.owner, amount, newDebtShares);
    }

    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params) external override returns (uint256 amount0, uint256 amount1) 
    {
        // this method is not allowed during transform - can be called directly on nftmanager if needed from transform contract
        if (transformedTokenId > 0) {
            revert TransformerNotAllowed();
        }

        address owner = loans[params.tokenId].owner;

        if (owner != msg.sender) {
            revert NotOwner();
        }

        (uint newDebtExchangeRateX96,) = _updateGlobalInterest();

        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(
                params.tokenId, 
                params.liquidity, 
                params.amount0Min, 
                params.amount1Min,
                params.deadline
            )
        );

        INonfungiblePositionManager.CollectParams memory collectParams = 
            INonfungiblePositionManager.CollectParams(
                params.tokenId, 
                params.recipient, 
                params.feeAmount0 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount0 + params.feeAmount0), 
                params.feeAmount1 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount1 + params.feeAmount1)
            );

        (amount0, amount1) = nonfungiblePositionManager.collect(collectParams);

        uint debt = _convertSharesToTokens(loans[params.tokenId].debtShares, newDebtExchangeRateX96);
        _requireLoanIsHealthyAndCollateralValid(params.tokenId, debt);

        emit WithdrawCollateral(params.tokenId, owner, params.recipient, amount0, amount1);
    }

    // repays borrowed tokens. can be denominated in token or debt share amount
    function repay(uint tokenId, uint amount, bool isShare) external override returns (uint) {

        (uint newDebtExchangeRateX96,) = _updateGlobalInterest();

        Loan storage loan = loans[tokenId];

        uint debt = _convertSharesToTokens(loan.debtShares, newDebtExchangeRateX96);

        uint repayedDebtShares;
        uint internalAmount;

        if (isShare) {
            if (amount > loan.debtShares) {
                revert RepayExceedsDebt();
            }
            repayedDebtShares = amount;
            internalAmount = _convertSharesToTokens(amount, newDebtExchangeRateX96);
            amount = _convertInternalToExternal(debt, true);
        } else {
            internalAmount = _convertExternalToInternal(amount);
            if (internalAmount > debt) {
                // repay all
                amount = _convertInternalToExternal(debt, true);
                // rounding rest is implicitly added to reserves
                repayedDebtShares = loan.debtShares;
            } else {
                repayedDebtShares = _convertTokensToShares(internalAmount, newDebtExchangeRateX96);
            }
        }    

        if (amount > 0) {
            IERC20(lendToken).transferFrom(msg.sender, address(this), amount);
        }

        loan.debtShares -= repayedDebtShares;
        debtSharesTotal -= repayedDebtShares;

        address owner = loan.owner;

        // if fully repayed
        if (loan.debtShares == 0) {
            _cleanupLoan(tokenId, owner);
        }

        emit Repay(tokenId, msg.sender, owner, amount, repayedDebtShares);

        return amount;
    }

    function deposit(uint256 amount) external override {
        
        uint internalAmount = _convertExternalToInternal(amount);

        (, uint newLendExchangeRateX96) = _updateGlobalInterest();
        
        // pull lend tokens
        IERC20(lendToken).transferFrom(msg.sender, address(this), amount);

        // mint corresponding amount to msg.sender
        uint sharesToMint = _convertTokensToShares(internalAmount, newLendExchangeRateX96);
        _mint(msg.sender, sharesToMint);

        if (totalSupply() > globalLendLimit) {
            revert GlobalLendLimit();
        }

        emit Deposit(msg.sender, amount, sharesToMint);
    }

    // withdraws lent tokens. can be denominated in token or share amount
    function withdraw(uint256 amount, bool isShare) external override {

        (uint newDebtExchangeRateX96, uint newLendExchangeRateX96) = _updateGlobalInterest();

        uint sharesToBurn;
        uint internalAmount;
        if (isShare) {
            sharesToBurn = amount;
            internalAmount = _convertSharesToTokens(sharesToBurn, newLendExchangeRateX96);
            amount = _convertInternalToExternal(internalAmount, false);
        } else {
            internalAmount = _convertExternalToInternal(amount);
            sharesToBurn = _convertTokensToShares(_convertExternalToInternal(amount), newLendExchangeRateX96);
        }        

        (,uint available,) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);
        if (available < internalAmount) {
            revert InsufficientLiquidity();
        }

        // fails if not enough shares
        _burn(msg.sender, sharesToBurn);

        // transfer lend token - after all checks done
        IERC20(lendToken).transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, sharesToBurn);
    }

    // function to liquidate position - needed lendtokens depending on current price
    function liquidate(uint tokenId) external override {

        // liquidation is not allowed during transformer mode
        if (transformedTokenId > 0) {
            revert TransformerNotAllowed();
        }

        (uint newDebtExchangeRateX96, uint newLendExchangeRateX96) = _updateGlobalInterest();

        uint debt = _convertSharesToTokens(loans[tokenId].debtShares, newDebtExchangeRateX96);

        (bool isHealthy, uint fullValue, uint collateralValue,,) = _checkLoanIsHealthy(tokenId, debt);
        if (isHealthy) {
            revert NotLiquidatable();
        }

        (uint leftover, uint liquidatorCost, uint reserveCost) = _calculateLiquidation(debt, fullValue, collateralValue);

        // take value from liquidator (rounded up)
        liquidatorCost = _convertInternalToExternal(liquidatorCost, true);
        IERC20(lendToken).transferFrom(msg.sender, address(this), liquidatorCost);
        // rounding rest is implicitly added to reserves

        address owner = loans[tokenId].owner;

        // send leftover to borrower if any
        if (leftover > 0) {
            leftover = _convertInternalToExternal(leftover, false);
            IERC20(lendToken).transfer(owner, leftover);
            // rounding rest is implicitly added to reserves
        }
        
        uint missing;

        // take remaining amount from reserves
        if (reserveCost > 0) {
            (,,uint reserves) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);

            // if not enough - democratize debt
            if (reserveCost > reserves) {
                missing = reserveCost - reserves;

                uint totalLent = _convertSharesToTokens(totalSupply(), newLendExchangeRateX96);

                // this lines distribute missing amount and remove it from all lent amount proportionally
                newLendExchangeRateX96 = (totalLent - missing) * newLendExchangeRateX96 / totalLent;
                lastLendExchangeRateX96 = newLendExchangeRateX96;
                emit ExchangeRateUpdate(newDebtExchangeRateX96, newLendExchangeRateX96);
            }
        }

        debtSharesTotal -= loans[tokenId].debtShares;

        // disarm loan and send collateral to liquidator
        _cleanupLoan(tokenId, msg.sender);

        emit Liquidate(tokenId, msg.sender, owner, _convertInternalToExternal(fullValue, false), liquidatorCost, leftover, _convertInternalToExternal(reserveCost, false), _convertInternalToExternal(missing, true));
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
            IERC20(lendToken).transfer(account, amount);
        }

        emit WithdrawReserves(amount, account);
    }

    // function to configure transformer contract 
    function setTransformer(address transformer, bool active) external onlyOwner {

        // protects protocol from owner trying to set dangerous transformer
        if (transformer == address(0) || transformer == address(this) || transformer == lendToken || transformer == address(nonfungiblePositionManager)) {
            revert TransformerNotAllowed();
        }

        transformerAllowList[transformer] = active;
        emit SetTransformer(transformer, active);
    }

    // function to set limits (this doesnt affect existing loans)
    function setLimits(uint _globalLendLimit, uint _globalDebtLimit) external onlyOwner {
        globalLendLimit = _convertExternalToInternal(_globalLendLimit);
        globalDebtLimit = _convertExternalToInternal(_globalDebtLimit);

        emit SetLimits(_globalLendLimit, _globalDebtLimit);
    }

    // function to set reserve factor - percentage difference between Debting and lending interest
    function setReserveFactor(uint32 _reserveFactorX32) external onlyOwner {
        reserveFactorX32 = _reserveFactorX32;
        emit SetReserveFactor(_reserveFactorX32);
    }

    // function to set reserve protection factor - percentage of globalLendAmount which can't be withdrawn by owner
    function setReserveProtectionFactor(uint32 _reserveProtectionFactorX32) external onlyOwner {
        reserveProtectionFactorX32 = _reserveProtectionFactorX32;
        emit SetReserveProtectionFactor(_reserveProtectionFactorX32);
    }

    // function to set token config
    // how much is collateral factor for this token
    // how much of it maybe used as collateral max measured in lendtoken quantity
    function setTokenConfig(address token, uint32 collateralFactorX32, uint216 collateralValueLimit) external onlyOwner {
        if (collateralFactorX32 > MAX_COLLATERAL_FACTOR_X32) {
            revert CollateralFactorExceedsMax();
        }
        tokenConfigs[token].collateralFactorX32 = collateralFactorX32;
        tokenConfigs[token].collateralValueLimit = uint216(_convertExternalToInternal(collateralValueLimit));
        emit SetTokenConfig(token, collateralFactorX32, collateralValueLimit);
    }

    ////////////////// INTERNAL FUNCTIONS

    // checks how much balance is available - excluding reserves
    function _getAvailableBalance(uint debtExchangeRateX96, uint lendExchangeRateX96) internal view returns (uint balance, uint available, uint reserves) {

        balance = _convertExternalToInternal(IERC20(lendToken).balanceOf(address(this)));
        uint debt = _convertSharesToTokens(debtSharesTotal, debtExchangeRateX96);
        uint lent = _convertSharesToTokens(totalSupply(), lendExchangeRateX96);

        reserves = balance + debt - lent;
        available = balance > reserves ? balance - reserves : 0;
    }

    // cleans up loan when it is closed because of replacement, repayment or liquidation
    // send the position in its current state to owner or liquidator
    function _cleanupLoan(uint tokenId, address reciever) internal {
        _updateCollateral(tokenId, 0, 0, 0, 0);
        delete loans[tokenId];
        nonfungiblePositionManager.safeTransferFrom(address(this), reciever, tokenId);
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

            emit ExchangeRateUpdate(newDebtExchangeRateX96, newLendExchangeRateX96);
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

    function _requireLoanIsHealthyAndCollateralValid(uint tokenId, uint debt) internal {
        (bool isHealthy, uint fullValue, uint collateralValue, uint price0X96, uint price1X96) = _checkLoanIsHealthy(tokenId, debt);
        if (!isHealthy) {
            revert CollateralFail();
        }

        // always <= Q96 (otherwise it would be unhealthy)
        uint debtRatioX96 = debt * Q96 / collateralValue;

        uint fullValueExternal = _convertInternalToExternal(fullValue, false);
        uint collateral0 = fullValueExternal * debtRatioX96 / price0X96;
        uint collateral1 = fullValueExternal * debtRatioX96 / price1X96;

        _updateCollateral(tokenId, collateral0, collateral1, price0X96, price1X96);
    }

    function _updateCollateral(uint tokenId, uint collateral0, uint collateral1, uint price0X96, uint price1X96) internal {

        // convert full value to both collateral tokens 
        uint previousCollateral0 = loans[tokenId].collateral0;
        uint previousCollateral1 = loans[tokenId].collateral1;

        (,,address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);

        // remove previous collateral - add new collateral
        if (previousCollateral0 > collateral0) {
            tokenConfigs[token0].collateralTotal -= previousCollateral0 - collateral0;
        } else {
            tokenConfigs[token0].collateralTotal += collateral0 - previousCollateral0;
        }
        if (previousCollateral1 > collateral1) {
            tokenConfigs[token1].collateralTotal -= previousCollateral1 - collateral1;
        } else {
            tokenConfigs[token1].collateralTotal += collateral1 - previousCollateral1;
        }

        // set collateral for loan
        loans[tokenId].collateral0 = collateral0;
        loans[tokenId].collateral1 = collateral1;

        
        // check if current value of "estimated" used collateral is more than allowed limit
        // if collateral is decreased - never revert
        if (collateral0 > previousCollateral0 && _convertExternalToInternal(tokenConfigs[token0].collateralTotal * price0X96 / Q96) > tokenConfigs[token0].collateralValueLimit) {
            revert CollateralValueLimit();
        }
        if (collateral1 > previousCollateral1 && _convertExternalToInternal(tokenConfigs[token1].collateralTotal * price1X96 / Q96) > tokenConfigs[token1].collateralValueLimit) {
            revert CollateralValueLimit();
        }
    }

    function _checkLoanIsHealthy(uint tokenId, uint debt) internal view returns (bool isHealthy, uint fullValue, uint collateralValue, uint price0X96, uint price1X96) {
        (fullValue,price0X96,price1X96) = oracle.getValue(tokenId, address(lendToken));
        fullValue = _convertExternalToInternal(fullValue);
        collateralValue = loans[tokenId].collateralFactorX32 * fullValue / Q32;
        isHealthy = collateralValue >= debt;
    }

    function _roundUp(uint amount) internal view returns (uint) {
        uint rest = amount % lendTokenMultiplier;
        return rest > 0 ? amount - rest + lendTokenMultiplier : amount;
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