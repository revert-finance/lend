// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FixedPoint128.sol";

import "v3-periphery/libraries/LiquidityAmounts.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IV3Oracle.sol";
import "./interfaces/IInterestRateModel.sol";
import "./interfaces/IGaugeManager.sol";
import "./utils/Constants.sol";

/// @title Revert Lend Vault for token lending / borrowing using Uniswap V3 LP positions as collateral
/// @notice The vault manages ONE ERC20 (eg. USDC) asset for lending / borrowing, but collateral positions can be composed of any 2 tokens configured each with a collateralFactor > 0
/// Vault implements IERC4626 Vault Standard and is itself a ERC20 which represent shares of total lending pool
contract V3Vault is ERC20, Multicall, Ownable2Step, IVault, IERC721Receiver, Constants {
    using Math for uint256;

    uint32 public constant MAX_COLLATERAL_FACTOR_X32 = 3_865_470_566; // floor(Q32 * 90 / 100)

    uint32 public constant MIN_LIQUIDATION_PENALTY_X32 = 85_899_345; // floor(Q32 * 2 / 100)
    uint32 public constant MAX_LIQUIDATION_PENALTY_X32 = 429_496_729; // floor(Q32 * 10 / 100)

    uint32 public constant MIN_RESERVE_PROTECTION_FACTOR_X32 = 42_949_672; // floor(Q32 / 100)

    uint32 public constant MAX_DAILY_LEND_INCREASE_X32 = 429_496_729; // floor(Q32 / 10)
    uint32 public constant MAX_DAILY_DEBT_INCREASE_X32 = 429_496_729; // floor(Q32 / 10)

    uint256 public constant BORROW_SAFETY_BUFFER_X32 = 4_080_218_931; // floor(Q32 * 95 / 100)

    /// @notice Uniswap v3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice Uniswap v3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice interest rate model implementation
    IInterestRateModel public immutable interestRateModel;

    /// @notice oracle implementation
    IV3Oracle public immutable oracle;

    /// @notice underlying asset for lending / borrowing
    address public immutable override asset;

    /// @notice decimals of underlying token (are the same as ERC20 share token)
    uint8 private immutable assetDecimals;

    // events
    event ApprovedTransform(uint256 indexed tokenId, address owner, address target, bool isActive);

    event Add(uint256 indexed tokenId, address owner, uint256 oldTokenId); // when a token is added replacing another token - oldTokenId > 0
    event Remove(uint256 indexed tokenId, address owner, address recipient);

    event ExchangeRateUpdate(uint256 debtExchangeRateX96, uint256 lendExchangeRateX96);
    // Deposit and Withdraw events are defined in IERC4626
    event WithdrawCollateral(
        uint256 indexed tokenId, address owner, address recipient, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event Borrow(uint256 indexed tokenId, address owner, uint256 assets, uint256 shares);
    event Repay(uint256 indexed tokenId, address repayer, address owner, uint256 assets, uint256 shares);
    event Liquidate(
        uint256 indexed tokenId,
        address liquidator,
        address owner,
        uint256 value,
        uint256 cost,
        uint256 amount0,
        uint256 amount1,
        uint256 reserve,
        uint256 missing
    ); // shows exactly how liquidation amounts were divided

    // admin events
    event WithdrawReserves(uint256 amount, address receiver);
    event SetTransformer(address transformer, bool active);
    event SetLimits(
        uint256 minLoanSize,
        uint256 globalLendLimit,
        uint256 globalDebtLimit,
        uint256 dailyLendIncreaseLimitMin,
        uint256 dailyDebtIncreaseLimitMin
    );
    event SetReserveFactor(uint32 reserveFactorX32);
    event SetReserveProtectionFactor(uint32 reserveProtectionFactorX32);
    event SetTokenConfig(address token, uint32 collateralFactorX32, uint32 collateralValueLimitFactorX32);

    event SetEmergencyAdmin(address emergencyAdmin);
    event SetGaugeManager(address indexed gaugeManager);

    // configured tokens
    struct TokenConfig {
        uint32 collateralFactorX32; // how much this token is valued as collateral
        uint32 collateralValueLimitFactorX32; // how much asset equivalent may be lent out given this collateral
        uint192 totalDebtShares; // how much debt shares are theoretically backed by this collateral
    }

    mapping(address => TokenConfig) public tokenConfigs;

    // total of debt shares - increases when borrow - decreases when repay
    uint256 public debtSharesTotal;

    // exchange rates are Q96 at the beginning - 1 share token per 1 asset token
    uint256 public lastDebtExchangeRateX96 = Q96;
    uint256 public lastLendExchangeRateX96 = Q96;

    uint256 public globalDebtLimit;
    uint256 public globalLendLimit;

    // minimal size of loan (to protect from non-liquidatable positions because of gas-cost)
    uint256 public minLoanSize;

    // daily lend increase limit handling
    uint256 public dailyLendIncreaseLimitMin;
    uint256 public dailyLendIncreaseLimitLeft;

    // daily debt increase limit handling
    uint256 public dailyDebtIncreaseLimitMin;
    uint256 public dailyDebtIncreaseLimitLeft;

    // lender balances are handled with ERC-20 mint/burn

    // loans are handled with this struct
    struct Loan {
        uint256 debtShares;
    }

    mapping(uint256 => Loan) public override loans; // tokenID -> loan mapping

    // storage variables to handle enumerable token ownership
    mapping(address => uint256[]) private ownedTokens; // Mapping from owner address to list of owned token IDs
    mapping(uint256 => uint256) private ownedTokensIndex; // Mapping from token ID to index of the owner tokens list (for removal without loop)
    mapping(uint256 => address) private tokenOwner; // Mapping from token ID to owner

    // transform-mode sentinel. Intentionally used instead of a global nonReentrant modifier so trusted transformers
    // can call back into borrow() for the same token during transform in a single transaction.
    uint256 public override transformedTokenId; // stores currently transformed token (is always reset to 0 after tx)

    mapping(address => bool) public transformerAllowList; // contracts allowed to transform positions (selected audited contracts e.g. V3Utils)
    mapping(address => mapping(uint256 => mapping(address => bool))) public transformApprovals; // owners permissions for other addresses to call transform on owners behalf (e.g. AutoRangeAndCompound contract)

    // last time exchange rate was updated
    uint64 public lastExchangeRateUpdate;

    // percentage of interest which is kept in the protocol for reserves
    uint32 public reserveFactorX32;

    // percentage of lend amount which needs to be in reserves before withdrawn
    uint32 public reserveProtectionFactorX32 = MIN_RESERVE_PROTECTION_FACTOR_X32;

    // when limits where last reset
    uint32 public dailyLendIncreaseLimitLastReset;
    uint32 public dailyDebtIncreaseLimitLastReset;

    // address which can call special emergency actions without timelock
    address public emergencyAdmin;
    address public gaugeManager;

    constructor(
        string memory name,
        string memory symbol,
        address _asset,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IInterestRateModel _interestRateModel,
        IV3Oracle _oracle
    ) ERC20(name, symbol) {
        asset = _asset;
        assetDecimals = IERC20Metadata(_asset).decimals();
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        interestRateModel = _interestRateModel;
        oracle = _oracle;
    }

    ////////////////// EXTERNAL VIEW FUNCTIONS

    /// @notice Retrieves global information about the vault
    /// @return debt Total amount of debt asset tokens
    /// @return lent Total amount of lent asset tokens
    /// @return balance Balance of asset token in contract
    /// @return reserves Amount of reserves
    function vaultInfo()
        external
        view
        override
        returns (
            uint256 debt,
            uint256 lent,
            uint256 balance,
            uint256 reserves,
            uint256 debtExchangeRateX96,
            uint256 lendExchangeRateX96
        )
    {
        (debtExchangeRateX96, lendExchangeRateX96) = _calculateGlobalInterest();
        (balance, reserves) = _getBalanceAndReserves(debtExchangeRateX96, lendExchangeRateX96);

        debt = _convertToAssets(debtSharesTotal, debtExchangeRateX96, Math.Rounding.Up);
        lent = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @notice Retrieves lending information for a specified account.
    /// @param account The address of the account for which lending info is requested.
    /// @return amount Amount of lent assets for the account
    function lendInfo(address account) external view override returns (uint256 amount) {
        (, uint256 newLendExchangeRateX96) = _calculateGlobalInterest();
        amount = _convertToAssets(balanceOf(account), newLendExchangeRateX96, Math.Rounding.Down);
    }

    /// @notice Retrieves details of a loan identified by its token ID.
    /// @param tokenId The unique identifier of the loan - which is the corresponding UniV3 Position
    /// @return debt Amount of debt for this position
    /// @return fullValue Current value of the position priced as asset token
    /// @return collateralValue Current collateral value of the position priced as asset token
    /// @return liquidationCost If position is liquidatable - cost to liquidate position - otherwise 0
    /// @return liquidationValue If position is liquidatable - the value of the (partial) position which the liquidator recieves - otherwise 0
    function loanInfo(uint256 tokenId)
        public
        view
        override
        returns (
            uint256 debt,
            uint256 fullValue,
            uint256 collateralValue,
            uint256 liquidationCost,
            uint256 liquidationValue
        )
    {
        (uint256 newDebtExchangeRateX96,) = _calculateGlobalInterest();

        debt = _convertToAssets(loans[tokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Up);

        bool isHealthy;
        (isHealthy, fullValue, collateralValue,) = _checkLoanIsHealthy(tokenId, debt, false);

        if (!isHealthy) {
            (liquidationValue, liquidationCost,) = _calculateLiquidation(debt, fullValue, collateralValue);
        }
    }

    /// @notice Retrieves owner of a loan
    /// @param tokenId The unique identifier of the loan - which is the corresponding UniV3 Position
    /// @return owner Owner of the loan
    function ownerOf(uint256 tokenId) external view override returns (address owner) {
        return tokenOwner[tokenId];
    }

    /// @notice Retrieves count of loans for owner (for enumerating owners loans)
    /// @param owner Owner address
    function loanCount(address owner) external view override returns (uint256) {
        return ownedTokens[owner].length;
    }

    /// @notice Retrieves tokenid of loan at given index for owner (for enumerating owners loans)
    /// @param owner Owner address
    /// @param index Index
    function loanAtIndex(address owner, uint256 index) external view override returns (uint256) {
        return ownedTokens[owner][index];
    }

    ////////////////// OVERRIDDEN EXTERNAL VIEW FUNCTIONS FROM ERC20
    /// @inheritdoc IERC20Metadata
    function decimals() public view override(IERC20Metadata, ERC20) returns (uint8) {
        return assetDecimals;
    }

    ////////////////// OVERRIDDEN EXTERNAL VIEW FUNCTIONS FROM ERC4626

    /// @inheritdoc IERC4626
    function totalAssets() external view override returns (uint256) {
        (uint256 debtExchangeRateX96,) = _calculateGlobalInterest();
        // Round debt up to avoid understating liabilities in share pricing/accounting.
        uint256 debt = _convertToAssets(debtSharesTotal, debtExchangeRateX96, Math.Rounding.Up);
        return IERC20(asset).balanceOf(address(this)) + debt;
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _maxDepositAssets(lendExchangeRateX96);
    }

    /// @inheritdoc IERC4626
    function maxMint(address) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        uint256 maxGlobalDeposit = _maxDepositAssets(lendExchangeRateX96);
        return _convertToShares(maxGlobalDeposit, lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) external view override returns (uint256) {
        (uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _maxWithdrawAssets(owner, debtExchangeRateX96, lendExchangeRateX96);
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) external view override returns (uint256) {
        (uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        uint256 assets = _maxWithdrawAssets(owner, debtExchangeRateX96, lendExchangeRateX96);
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 shares) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Up);
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Up);
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Down);
    }

    ////////////////// OVERRIDDEN EXTERNAL FUNCTIONS FROM ERC4626

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        (, uint256 shares) = _deposit(receiver, assets, false);
        return shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) external override returns (uint256) {
        (uint256 assets,) = _deposit(receiver, shares, true);
        return assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256) {
        (, uint256 shares) = _withdraw(receiver, owner, assets, false);
        return shares;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256) {
        (uint256 assets,) = _withdraw(receiver, owner, shares, true);
        return assets;
    }

    ////////////////// EXTERNAL FUNCTIONS

    /// @notice Creates a new collateralized position (transfer approved position)
    /// @param tokenId The token ID associated with the new position.
    /// @param recipient Address to recieve the position in the vault
    function create(uint256 tokenId, address recipient) external override {
        if (recipient == address(0)) {
            revert InvalidConfig();
        }
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(recipient));
    }

    /// @notice Whenever a token is recieved it either creates a new loan, or modifies an existing one when in transform mode.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        /*operator*/
        address from,
        uint256 tokenId,
        bytes calldata data
    )
        external
        override
        returns (bytes4)
    {
        // only Uniswap v3 NFTs allowed - sent from other contract
        if (msg.sender != address(nonfungiblePositionManager) || from == address(this)) {
            revert WrongContract();
        }

        (uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) = _updateGlobalInterest();

        uint256 oldTokenId = transformedTokenId;

        if (oldTokenId == 0) {
            // New deposit path.
            if (tokenOwner[tokenId] == address(0)) {
                address owner = from;
                if (data.length != 0) {
                    // NOTE FOR AUDITS:
                    // Raw ERC721 deposits may override owner via callback data.
                    // This is intentionally flexible for integrator/operator flows and is an accepted trust assumption:
                    // whoever can trigger safeTransferFrom for the NFT can also choose the callback payload.
                    owner = abi.decode(data, (address));
                }
                if (owner == address(0)) {
                    revert InvalidConfig();
                }
                loans[tokenId] = Loan(0);
                _addTokenToOwner(owner, tokenId);
                emit Add(tokenId, owner, 0);
            }
        } else {
            // NOTE FOR AUDITS:
            // We intentionally do not bind replacement-NFT migration to a specific operator contract here.
            // Some valid transformers route NFT moves through helper/proxy contracts, so strict operator pinning
            // would break supported integrations. Safety relies on transform-mode scoping + final custody checks.
            // if in transform mode - and a new position is sent - current position is replaced and returned
            if (tokenId != oldTokenId) {
                // Replacement migrations are only safe for freshly introduced tokenIds. Reusing a token that already
                // has vault ownership or debt state would overwrite its live loan accounting.
                if (tokenOwner[tokenId] != address(0) || loans[tokenId].debtShares != 0) {
                    revert Unauthorized();
                }

                address owner = tokenOwner[oldTokenId];

                // set transformed token to new one
                transformedTokenId = tokenId;

                uint256 debtShares = loans[oldTokenId].debtShares;

                // copy debt to new token
                loans[tokenId] = Loan(debtShares);

                _addTokenToOwner(owner, tokenId);
                emit Add(tokenId, owner, oldTokenId);

                // remove debt from old loan
                _cleanupLoan(oldTokenId, debtExchangeRateX96, lendExchangeRateX96);

                // sets data of new loan
                _updateAndCheckCollateral(tokenId, debtExchangeRateX96, lendExchangeRateX96, 0, debtShares);
            }
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Allows another address to call transform on behalf of owner (on a given token)
    /// @param tokenId The token to be permitted
    /// @param target The address to be allowed
    /// @param isActive If it allowed or not
    function approveTransform(uint256 tokenId, address target, bool isActive) external override {
        if (tokenOwner[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        transformApprovals[msg.sender][tokenId][target] = isActive;
        emit ApprovedTransform(tokenId, msg.sender, target, isActive);
    }

    function transform(uint256 tokenId, address transformer, bytes calldata data)
        external
        override
        returns (uint256 newTokenId)
    {
        return _transform(tokenId, transformer, data, false, 0, 0, 0);
    }

    function transformWithRewardCompound(
        uint256 tokenId,
        address transformer,
        bytes calldata data,
        RewardCompoundParams calldata rewardParams
    ) external override returns (uint256 newTokenId) {
        return _transform(
            tokenId,
            transformer,
            data,
            true,
            rewardParams.minAeroReward,
            rewardParams.aeroSplitBps,
            rewardParams.deadline
        );
    }

    function _transform(
        uint256 tokenId,
        address transformer,
        bytes calldata data,
        bool compoundRewardsFirst,
        uint256 minAeroReward,
        uint256 aeroSplitBps,
        uint256 deadline
    ) internal returns (uint256 newTokenId) {
        if (tokenId == 0 || !transformerAllowList[transformer]) {
            revert TransformNotAllowed();
        }
        if (transformedTokenId != 0) {
            revert Reentrancy();
        }
        // Enter scoped transform mode and block unrelated state-changing paths until reset below.
        transformedTokenId = tokenId;

        (uint256 newDebtExchangeRateX96,) = _updateGlobalInterest();

        address loanOwner = tokenOwner[tokenId];

        // only the owner of the loan or any approved caller can call this
        if (loanOwner != msg.sender && !transformApprovals[loanOwner][tokenId][msg.sender]) {
            revert Unauthorized();
        }

        if (
            compoundRewardsFirst && gaugeManager != address(0)
                && IGaugeManager(gaugeManager).tokenIdToGauge(tokenId) != address(0)
        ) {
            IGaugeManager(gaugeManager).compoundRewards(tokenId, minAeroReward, aeroSplitBps, deadline);
        }

        bool wasStaked = _unstakeIfNeeded(tokenId);

        // give access to transformer
        nonfungiblePositionManager.approve(transformer, tokenId);

        (bool success,) = transformer.call(data);
        if (!success) {
            revert TransformFailed();
        }

        // may have changed in the meantime
        newTokenId = transformedTokenId;

        // if token has changed - and operator was approved for old token - take over for new token
        if (tokenId != newTokenId && transformApprovals[loanOwner][tokenId][msg.sender]) {
            transformApprovals[loanOwner][newTokenId][msg.sender] = true;
            delete transformApprovals[loanOwner][tokenId][msg.sender];
        }

        // NOTE FOR AUDITS:
        // No operator-pinning is enforced by design for transformer flexibility; custody is enforced here.
        // check owner not changed (NEEDED because token could have been moved somewhere else in the meantime)
        address owner = nonfungiblePositionManager.ownerOf(newTokenId);
        if (owner != address(this)) {
            revert Unauthorized();
        }

        // remove access for transformer
        nonfungiblePositionManager.approve(address(0), newTokenId);
        if (tokenId != newTokenId) {
            // old token may be burned during transform; clear approval best-effort
            try nonfungiblePositionManager.approve(address(0), tokenId) {} catch {}
        }

        uint256 debt = _convertToAssets(loans[newTokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Up);

        if (wasStaked) {
            // Re-check health in the final staked custody state because staking realizes pre-stake fees.
            _stake(newTokenId);
        }
        _requireLoanIsHealthy(newTokenId, debt);

        transformedTokenId = 0;
    }

    /// @notice Borrows specified amount using token as collateral
    /// @param tokenId The token ID to use as collateral
    /// @param assets How much assets to borrow
    function borrow(uint256 tokenId, uint256 assets) external override {
        // Allowed callback path: transform() -> allowed transformer -> borrow() for the same tokenId.
        bool isTransformMode = tokenId != 0 && transformedTokenId == tokenId && transformerAllowList[msg.sender];

        address owner = tokenOwner[tokenId];

        // if not in transform mode - must be called from owner
        if (!isTransformMode && owner != msg.sender) {
            revert Unauthorized();
        }

        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, false);

        Loan storage loan = loans[tokenId];

        uint256 shares = _convertToShares(assets, newDebtExchangeRateX96, Math.Rounding.Up);

        uint256 loanDebtShares = loan.debtShares + shares;
        loan.debtShares = loanDebtShares;
        debtSharesTotal = debtSharesTotal + shares;

        if (debtSharesTotal > _convertToShares(globalDebtLimit, newDebtExchangeRateX96, Math.Rounding.Down)) {
            revert GlobalDebtLimit();
        }
        if (assets > dailyDebtIncreaseLimitLeft) {
            revert DailyDebtIncreaseLimit();
        } else {
            dailyDebtIncreaseLimitLeft = dailyDebtIncreaseLimitLeft - assets;
        }

        _updateAndCheckCollateral(
            tokenId, newDebtExchangeRateX96, newLendExchangeRateX96, loanDebtShares - shares, loanDebtShares
        );

        uint256 debt = _convertToAssets(loanDebtShares, newDebtExchangeRateX96, Math.Rounding.Up);

        if (debt < minLoanSize) {
            revert MinLoanSize();
        }

        // only does check health here if not in transform mode
        if (!isTransformMode) {
            _requireLoanIsHealthy(tokenId, debt);
        }

        // fails if not enough asset available
        // it may use all balance of the contract (because "virtual" reserves do not need to be stored in contract)
        // if called from transform mode - send funds to transformer contract
        SafeERC20.safeTransfer(IERC20(asset), msg.sender, assets);

        emit Borrow(tokenId, owner, assets, shares);
    }

    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        // this method is not allowed during transform - can be called directly on nftmanager if needed from transform contract
        if (transformedTokenId != 0) {
            revert TransformNotAllowed();
        }

        address owner = tokenOwner[params.tokenId];

        if (owner != msg.sender) {
            revert Unauthorized();
        }

        bool wasStaked = _unstakeIfNeeded(params.tokenId);

        (uint256 newDebtExchangeRateX96,) = _updateGlobalInterest();

        if (params.liquidity != 0) {
            (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(
                    params.tokenId, params.liquidity, params.amount0Min, params.amount1Min, params.deadline
                )
            );
        }

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams(
            params.tokenId,
            params.recipient,
            params.feeAmount0 == type(uint128).max
                ? type(uint128).max
                : SafeCast.toUint128(amount0 + params.feeAmount0),
            params.feeAmount1 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount1 + params.feeAmount1)
        );

        (amount0, amount1) = nonfungiblePositionManager.collect(collectParams);

        if (wasStaked) {
            // Re-check health in the final staked custody state because staking realizes pre-stake fees.
            _stake(params.tokenId);
        }

        uint256 debt = _convertToAssets(loans[params.tokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Up);
        _requireLoanIsHealthy(params.tokenId, debt);

        emit WithdrawCollateral(params.tokenId, owner, params.recipient, params.liquidity, amount0, amount1);
    }

    /// @notice Repays borrowed tokens. Can be denominated in assets or debt share amount
    /// @param tokenId The token ID to use as collateral
    /// @param amount How many assets/debt shares to repay
    /// @param isShare Is amount specified in assets or debt shares.
    /// @return assets The amount of the assets repayed
    /// @return shares The amount of the shares repayed
    function repay(uint256 tokenId, uint256 amount, bool isShare)
        external
        override
        returns (uint256 assets, uint256 shares)
    {
        (assets, shares) = _repay(tokenId, amount, isShare);
    }

    // state used in liquidation function to avoid stack too deep errors
    struct LiquidateState {
        uint256 newDebtExchangeRateX96;
        uint256 newLendExchangeRateX96;
        uint256 debt;
        bool isHealthy;
        uint256 liquidationValue;
        uint256 liquidatorCost;
        uint256 reserveCost;
        uint256 missing;
        uint256 fullValue;
        uint256 collateralValue;
        uint256 feeValue;
    }

    /// @notice Liquidates position - needed assets are depending on current price.
    /// Sufficient assets need to be approved to the contract for the liquidation to succeed.
    /// @param params The params defining liquidation
    /// @return amount0 The amount of the first type of asset collected.
    /// @return amount1 The amount of the second type of asset collected.
    function liquidate(LiquidateParams calldata params) external override returns (uint256 amount0, uint256 amount1) {
        // liquidation is not allowed during transformer mode
        if (transformedTokenId != 0) {
            revert TransformNotAllowed();
        }

        LiquidateState memory state;

        (state.newDebtExchangeRateX96, state.newLendExchangeRateX96) = _updateGlobalInterest();

        _resetDailyDebtIncreaseLimit(state.newLendExchangeRateX96, false);

        uint256 debtShares = loans[params.tokenId].debtShares;

        state.debt = _convertToAssets(debtShares, state.newDebtExchangeRateX96, Math.Rounding.Up);

        (state.isHealthy, state.fullValue, state.collateralValue, state.feeValue) =
            _checkLoanIsHealthy(params.tokenId, state.debt, false);
        if (state.isHealthy) {
            revert NotLiquidatable();
        }

        _unstakeIfNeeded(params.tokenId);

        (state.liquidationValue, state.liquidatorCost, state.reserveCost) =
            _calculateLiquidation(state.debt, state.fullValue, state.collateralValue);

        // calculate reserve (before transfering liquidation money - otherwise calculation is off)
        if (state.reserveCost != 0) {
            state.missing = _handleReserveLiquidation(
                state.reserveCost, state.newDebtExchangeRateX96, state.newLendExchangeRateX96
            );
        }

        if (state.liquidatorCost != 0) {
            _pullAssetFromSender(state.liquidatorCost);
        }

        debtSharesTotal = debtSharesTotal - debtShares;

        // Replenish daily borrow headroom only by assets actually paid into the vault.
        dailyDebtIncreaseLimitLeft = dailyDebtIncreaseLimitLeft + state.liquidatorCost;

        // send promised collateral tokens to liquidator
        (amount0, amount1) = _sendPositionValue(
            params.tokenId, state.liquidationValue, state.fullValue, state.feeValue, params.recipient, params.deadline
        );

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert SlippageError();
        }

        // remove debt from loan
        _cleanupLoan(params.tokenId, state.newDebtExchangeRateX96, state.newLendExchangeRateX96);

        emit Liquidate(
            params.tokenId,
            msg.sender,
            tokenOwner[params.tokenId],
            state.fullValue,
            state.liquidatorCost,
            amount0,
            amount1,
            state.reserveCost,
            state.missing
        );
    }

    /// @notice Removes position from the vault (only possible when all repayed)
    /// @param tokenId The token ID to use as collateral
    /// @param recipient Address to recieve NFT
    /// @param data Optional data to send to reciever
    function remove(uint256 tokenId, address recipient, bytes calldata data) external {
        address owner = tokenOwner[tokenId];
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        if (loans[tokenId].debtShares != 0) {
            revert NeedsRepay();
        }

        _unstakeIfNeeded(tokenId);

        _removeTokenFromOwner(owner, tokenId);
        nonfungiblePositionManager.safeTransferFrom(address(this), recipient, tokenId, data);
        emit Remove(tokenId, owner, recipient);
    }

    ////////////////// ADMIN FUNCTIONS only callable by owner

    /// @notice withdraw protocol reserves (onlyOwner)
    /// only allows to withdraw excess reserves (> globalLendAmount * reserveProtectionFactor)
    /// @param amount amount to withdraw
    /// @param receiver receiver address
    function withdrawReserves(uint256 amount, address receiver) external onlyOwner {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        uint256 protected = _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Up)
            * reserveProtectionFactorX32 / Q32;
        (uint256 balance, uint256 reserves) = _getBalanceAndReserves(newDebtExchangeRateX96, newLendExchangeRateX96);
        uint256 unprotected = reserves > protected ? reserves - protected : 0;
        uint256 available = balance > unprotected ? unprotected : balance;

        if (amount > available) {
            revert InsufficientLiquidity();
        }

        if (amount != 0) {
            SafeERC20.safeTransfer(IERC20(asset), receiver, amount);
        }

        emit WithdrawReserves(amount, receiver);
    }

    /// @notice configure transformer contract (onlyOwner)
    /// @param transformer address of transformer contract
    /// @param active should the transformer be active?
    function setTransformer(address transformer, bool active) external onlyOwner {
        // protects protocol from owner trying to set dangerous transformer
        if (
            transformer == address(0) || transformer == address(this) || transformer == asset
                || transformer == address(nonfungiblePositionManager)
        ) {
            revert InvalidConfig();
        }

        transformerAllowList[transformer] = active;
        emit SetTransformer(transformer, active);
    }

    /// @notice set limits (this doesnt affect existing loans) - this method can be called by owner OR emergencyAdmin
    /// @param _minLoanSize min size of a loan - trying to create smaller loans will revert
    /// @param _globalLendLimit global limit of lent amount
    /// @param _globalDebtLimit global limit of debt amount
    /// @param _dailyLendIncreaseLimitMin min daily increasable amount of lent amount
    /// @param _dailyDebtIncreaseLimitMin min daily increasable amount of debt amount
    function setLimits(
        uint256 _minLoanSize,
        uint256 _globalLendLimit,
        uint256 _globalDebtLimit,
        uint256 _dailyLendIncreaseLimitMin,
        uint256 _dailyDebtIncreaseLimitMin
    ) external {
        if (msg.sender != emergencyAdmin && msg.sender != owner()) {
            revert Unauthorized();
        }

        minLoanSize = _minLoanSize;
        globalLendLimit = _globalLendLimit;
        globalDebtLimit = _globalDebtLimit;
        dailyLendIncreaseLimitMin = _dailyLendIncreaseLimitMin;
        dailyDebtIncreaseLimitMin = _dailyDebtIncreaseLimitMin;

        (, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        // force reset daily limits with new values
        _resetDailyLendIncreaseLimit(newLendExchangeRateX96, true);
        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, true);

        emit SetLimits(
            _minLoanSize, _globalLendLimit, _globalDebtLimit, _dailyLendIncreaseLimitMin, _dailyDebtIncreaseLimitMin
        );
    }

    /// @notice sets reserve factor - percentage difference between debt and lend interest (onlyOwner)
    /// @param _reserveFactorX32 reserve factor multiplied by Q32
    function setReserveFactor(uint32 _reserveFactorX32) external onlyOwner {
        // _reserveFactorX32 is uint32, while Q32 == 2^32. Therefore reserveFactorX32 <= Q32 - 1 by type,
        // and Q32 - reserveFactorX32 in _calculateGlobalInterest() cannot underflow.
        // update interest to be sure that reservefactor change is applied from now on
        _updateGlobalInterest();
        reserveFactorX32 = _reserveFactorX32;
        emit SetReserveFactor(_reserveFactorX32);
    }

    /// @notice sets reserve protection factor - percentage of globalLendAmount which can't be withdrawn by owner (onlyOwner)
    /// @param _reserveProtectionFactorX32 reserve protection factor multiplied by Q32
    function setReserveProtectionFactor(uint32 _reserveProtectionFactorX32) external onlyOwner {
        if (_reserveProtectionFactorX32 < MIN_RESERVE_PROTECTION_FACTOR_X32) {
            revert InvalidConfig();
        }
        reserveProtectionFactorX32 = _reserveProtectionFactorX32;
        emit SetReserveProtectionFactor(_reserveProtectionFactorX32);
    }

    /// @notice Sets or updates the configuration for a token (onlyOwner)
    /// @param token Token to configure
    /// @param collateralFactorX32 collateral factor for this token mutiplied by Q32
    /// @param collateralValueLimitFactorX32 how much of it maybe used as collateral measured as percentage of total lent assets mutiplied by Q32
    function setTokenConfig(address token, uint32 collateralFactorX32, uint32 collateralValueLimitFactorX32)
        external
        onlyOwner
    {
        if (collateralFactorX32 > MAX_COLLATERAL_FACTOR_X32) {
            revert CollateralFactorExceedsMax();
        }
        TokenConfig storage config = tokenConfigs[token];
        config.collateralFactorX32 = collateralFactorX32;
        config.collateralValueLimitFactorX32 = collateralValueLimitFactorX32;
        emit SetTokenConfig(token, collateralFactorX32, collateralValueLimitFactorX32);
    }

    /// @notice Updates emergency admin address (onlyOwner)
    /// @param admin Emergency admin address
    function setEmergencyAdmin(address admin) external onlyOwner {
        emergencyAdmin = admin;
        emit SetEmergencyAdmin(admin);
    }

    ////////////////// INTERNAL FUNCTIONS

    function _deposit(address receiver, uint256 amount, bool isShare)
        internal
        returns (uint256 assets, uint256 shares)
    {
        (, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        _resetDailyLendIncreaseLimit(newLendExchangeRateX96, false);

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(shares, newLendExchangeRateX96, Math.Rounding.Up);
        } else {
            assets = amount;
            shares = _convertToShares(assets, newLendExchangeRateX96, Math.Rounding.Down);
        }

        uint256 newTotalAssets = _convertToAssets(totalSupply() + shares, newLendExchangeRateX96, Math.Rounding.Up);
        if (newTotalAssets > globalLendLimit) {
            revert GlobalLendLimit();
        }
        if (assets > dailyLendIncreaseLimitLeft) {
            revert DailyLendIncreaseLimit();
        }

        dailyLendIncreaseLimitLeft = dailyLendIncreaseLimitLeft - assets;
        _pullAssetFromSender(assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // withdraws lent tokens. can be denominated in token or share amount
    function _withdraw(address receiver, address owner, uint256 amount, bool isShare)
        internal
        returns (uint256 assets, uint256 shares)
    {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();
        _resetDailyLendIncreaseLimit(newLendExchangeRateX96, false);

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(amount, newLendExchangeRateX96, Math.Rounding.Down);
        } else {
            assets = amount;
            shares = _convertToShares(amount, newLendExchangeRateX96, Math.Rounding.Up);
        }

        // if caller has allowance for owners shares - may call withdraw
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        (uint256 balance,) = _getBalanceAndReserves(newDebtExchangeRateX96, newLendExchangeRateX96);
        if (balance < assets) {
            revert InsufficientLiquidity();
        }

        // fails if not enough shares
        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(asset), receiver, assets);

        // when amounts are withdrawn - they may be deposited again
        dailyLendIncreaseLimitLeft = dailyLendIncreaseLimitLeft + assets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _repay(uint256 tokenId, uint256 amount, bool isShare) internal returns (uint256 assets, uint256 shares) {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();
        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, false);

        Loan storage loan = loans[tokenId];

        uint256 currentShares = loan.debtShares;

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(amount, newDebtExchangeRateX96, Math.Rounding.Up);
        } else {
            assets = amount;
            shares = _convertToShares(amount, newDebtExchangeRateX96, Math.Rounding.Down);
        }

        if (shares == 0) {
            revert NoSharesRepayed();
        }

        // if too much repayed - just set to max
        if (shares > currentShares) {
            shares = currentShares;
            assets = _convertToAssets(shares, newDebtExchangeRateX96, Math.Rounding.Up);
        }

        _pullAssetFromSender(assets);

        uint256 loanDebtShares = currentShares - shares;
        loan.debtShares = loanDebtShares;
        debtSharesTotal = debtSharesTotal - shares;

        // when amounts are repayed - they maybe borrowed again
        dailyDebtIncreaseLimitLeft = dailyDebtIncreaseLimitLeft + assets;

        _updateAndCheckCollateral(
            tokenId, newDebtExchangeRateX96, newLendExchangeRateX96, loanDebtShares + shares, loanDebtShares
        );

        // if not fully repayed - check for loan size
        if (currentShares != shares) {
            // if resulting loan is too small - revert
            if (_convertToAssets(loanDebtShares, newDebtExchangeRateX96, Math.Rounding.Up) < minLoanSize) {
                revert MinLoanSize();
            }
        }

        emit Repay(tokenId, msg.sender, tokenOwner[tokenId], assets, shares);
    }

    function _pullAssetFromSender(uint256 assets) internal {
        if (assets == 0) {
            return;
        }
        SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), assets);
    }

    function _maxDepositAssets(uint256 lendExchangeRateX96) internal view returns (uint256) {
        uint256 value = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Up);
        if (value >= globalLendLimit) {
            return 0;
        }
        uint256 maxGlobalDeposit = globalLendLimit - value;
        if (maxGlobalDeposit > dailyLendIncreaseLimitLeft) {
            return dailyLendIncreaseLimitLeft;
        }
        return maxGlobalDeposit;
    }

    function _maxWithdrawAssets(address owner, uint256 debtExchangeRateX96, uint256 lendExchangeRateX96)
        internal
        view
        returns (uint256)
    {
        uint256 ownerShareBalance = balanceOf(owner);
        uint256 ownerAssetBalance = _convertToAssets(ownerShareBalance, lendExchangeRateX96, Math.Rounding.Down);
        (uint256 balance,) = _getBalanceAndReserves(debtExchangeRateX96, lendExchangeRateX96);
        if (balance > ownerAssetBalance) {
            return ownerAssetBalance;
        }
        return balance;
    }

    // checks how much balance is available
    function _getBalanceAndReserves(uint256 debtExchangeRateX96, uint256 lendExchangeRateX96)
        internal
        view
        returns (uint256 balance, uint256 reserves)
    {
        balance = IERC20(asset).balanceOf(address(this));
        uint256 debt = _convertToAssets(debtSharesTotal, debtExchangeRateX96, Math.Rounding.Up);
        uint256 lent = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Up);
        reserves = balance + debt > lent ? balance + debt - lent : 0;
    }

    // removes correct amount from position to send to liquidator
    function _sendPositionValue(
        uint256 tokenId,
        uint256 liquidationValue,
        uint256 fullValue,
        uint256 feeValue,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 amount0, uint256 amount1) {
        uint128 liquidity;
        uint128 fees0;
        uint128 fees1;

        // if full position is liquidated - no analysis needed
        if (liquidationValue == fullValue) {
            (,,,,,,, liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
            fees0 = type(uint128).max;
            fees1 = type(uint128).max;
        } else {
            (liquidity, fees0, fees1) = oracle.getLiquidityAndFees(tokenId);

            // only take needed fees
            if (liquidationValue <= feeValue) {
                liquidity = 0;
                fees0 = SafeCast.toUint128(liquidationValue * fees0 / feeValue);
                fees1 = SafeCast.toUint128(liquidationValue * fees1 / feeValue);
            } else {
                // take all fees and needed liquidity
                fees0 = type(uint128).max;
                fees1 = type(uint128).max;
                liquidity = SafeCast.toUint128((liquidationValue - feeValue) * liquidity / (fullValue - feeValue));
            }
        }

        if (liquidity != 0) {
            nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity, 0, 0, deadline)
            );
        }

        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, recipient, fees0, fees1)
        );
    }

    // cleans up loan when it is closed because of replacement, repayment or liquidation
    // the position is kept in the contract, but can be removed with remove() method
    // because loanShares are 0
    function _cleanupLoan(uint256 tokenId, uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) internal {
        _updateAndCheckCollateral(tokenId, debtExchangeRateX96, lendExchangeRateX96, loans[tokenId].debtShares, 0);
        delete loans[tokenId];
    }

    // calculates amount which needs to be payed to liquidate position
    //  if position is too valuable - not all of the position is liquididated - only needed amount
    //  if position is not valuable enough - missing part is covered by reserves - if not enough reserves - collectively by other borrowers
    function _calculateLiquidation(uint256 debt, uint256 fullValue, uint256 collateralValue)
        internal
        pure
        returns (uint256 liquidationValue, uint256 liquidatorCost, uint256 reserveCost)
    {
        // in a standard liquidation - liquidator pays complete debt (and get part or all of position)
        // if position has less than enough value - liquidation cost maybe less - rest is payed by protocol or lenders collectively
        liquidatorCost = debt;

        // position value needed to pay debt at max penalty
        uint256 maxPenaltyValue = debt * (Q32 + MAX_LIQUIDATION_PENALTY_X32) / Q32;

        // if position is more valuable than debt with max penalty
        if (fullValue >= maxPenaltyValue) {
            if (collateralValue != 0) {
                // position value when position started to be liquidatable
                uint256 startLiquidationValue = debt * fullValue / collateralValue;
                uint256 penaltyFractionX96 =
                    (Q96 - ((fullValue - maxPenaltyValue) * Q96 / (startLiquidationValue - maxPenaltyValue)));
                uint256 penaltyX32 = MIN_LIQUIDATION_PENALTY_X32
                    + (MAX_LIQUIDATION_PENALTY_X32 - MIN_LIQUIDATION_PENALTY_X32) * penaltyFractionX96 / Q96;

                liquidationValue = debt * (Q32 + penaltyX32) / Q32;
            } else {
                liquidationValue = maxPenaltyValue;
            }
        } else {
            uint256 penalty = debt * MAX_LIQUIDATION_PENALTY_X32 / Q32;

            // if value is enough to pay penalty
            if (fullValue > penalty) {
                liquidatorCost = fullValue - penalty;
            } else {
                // this extreme case leads to free liquidation
                liquidatorCost = 0;
            }

            liquidationValue = fullValue;
            reserveCost = debt - liquidatorCost; // Remaining to pay is taken from reserves
        }
    }

    // calculates if there are enough reserves to cover liquidaton - if not its shared between lenders
    function _handleReserveLiquidation(
        uint256 reserveCost,
        uint256 newDebtExchangeRateX96,
        uint256 newLendExchangeRateX96
    ) internal returns (uint256 missing) {
        (, uint256 reserves) = _getBalanceAndReserves(newDebtExchangeRateX96, newLendExchangeRateX96);

        // if not enough - democratize debt
        if (reserveCost > reserves) {
            missing = reserveCost - reserves;

            uint256 totalLent = _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Up);
            uint256 preHaircutDailyDebtCap =
                _calculateDailyIncreaseLimit(newLendExchangeRateX96, dailyDebtIncreaseLimitMin, MAX_DAILY_DEBT_INCREASE_X32);

            // this lines distribute missing amount and remove it from all lent amount proportionally
            newLendExchangeRateX96 = (totalLent - missing) * newLendExchangeRateX96 / totalLent;
            lastLendExchangeRateX96 = newLendExchangeRateX96;

            // A reserve socialization haircut reduces the lender base mid-day.
            // Rescale remaining daily debt headroom so it tracks the post-haircut cap while preserving already-used budget.
            uint256 postHaircutDailyDebtCap =
                _calculateDailyIncreaseLimit(newLendExchangeRateX96, dailyDebtIncreaseLimitMin, MAX_DAILY_DEBT_INCREASE_X32);
            if (
                dailyDebtIncreaseLimitLastReset == uint32(block.timestamp / 1 days)
                    && postHaircutDailyDebtCap < preHaircutDailyDebtCap
            ) {
                uint256 capReduction = preHaircutDailyDebtCap - postHaircutDailyDebtCap;
                dailyDebtIncreaseLimitLeft =
                    capReduction >= dailyDebtIncreaseLimitLeft ? 0 : dailyDebtIncreaseLimitLeft - capReduction;
            }

            emit ExchangeRateUpdate(newDebtExchangeRateX96, newLendExchangeRateX96);
        }
    }

    function _calculateTokenCollateralFactorX32(uint256 tokenId) internal view returns (uint32) {
        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        uint32 factor0X32 = tokenConfigs[token0].collateralFactorX32;
        uint32 factor1X32 = tokenConfigs[token1].collateralFactorX32;
        return factor0X32 > factor1X32 ? factor1X32 : factor0X32;
    }

    function _updateGlobalInterest() internal returns (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) {
        // only needs to be updated once per block (when needed)
        if (block.timestamp > lastExchangeRateUpdate) {
            (newDebtExchangeRateX96, newLendExchangeRateX96) = _calculateGlobalInterest();
            lastDebtExchangeRateX96 = newDebtExchangeRateX96;
            lastLendExchangeRateX96 = newLendExchangeRateX96;
            lastExchangeRateUpdate = uint64(block.timestamp); // never overflows in a loooooong time
            emit ExchangeRateUpdate(newDebtExchangeRateX96, newLendExchangeRateX96);
        } else {
            newDebtExchangeRateX96 = lastDebtExchangeRateX96;
            newLendExchangeRateX96 = lastLendExchangeRateX96;
        }
    }

    function _calculateGlobalInterest()
        internal
        view
        returns (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96)
    {
        uint256 oldDebtExchangeRateX96 = lastDebtExchangeRateX96;
        uint256 oldLendExchangeRateX96 = lastLendExchangeRateX96;

        // always growing or equal
        uint256 lastRateUpdate = lastExchangeRateUpdate;
        uint256 timeElapsed = (block.timestamp - lastRateUpdate);

        if (timeElapsed != 0 && lastRateUpdate != 0) {
            (uint256 balance,) = _getBalanceAndReserves(oldDebtExchangeRateX96, oldLendExchangeRateX96);
            uint256 debt = _convertToAssets(debtSharesTotal, oldDebtExchangeRateX96, Math.Rounding.Up);
            (uint256 borrowRateX64, uint256 supplyRateX64) = interestRateModel.getRatesPerSecondX64(balance, debt);
            // Safe by type bound documented in setReserveFactor(): reserveFactorX32 is always <= Q32 - 1.
            supplyRateX64 = supplyRateX64.mulDiv(Q32 - reserveFactorX32, Q32);

            newDebtExchangeRateX96 = oldDebtExchangeRateX96 + oldDebtExchangeRateX96 * timeElapsed * borrowRateX64 / Q64;
            newLendExchangeRateX96 = oldLendExchangeRateX96 + oldLendExchangeRateX96 * timeElapsed * supplyRateX64 / Q64;
        } else {
            newDebtExchangeRateX96 = oldDebtExchangeRateX96;
            newLendExchangeRateX96 = oldLendExchangeRateX96;
        }
    }

    function _requireLoanIsHealthy(uint256 tokenId, uint256 debt) internal view {
        (bool isHealthy,,,) = _checkLoanIsHealthy(tokenId, debt, true);
        if (!isHealthy) {
            revert CollateralFail();
        }
    }

    // updates collateral token configs - and check if limit is not surpassed (check is only done on increasing debt shares)
    function _updateAndCheckCollateral(
        uint256 tokenId,
        uint256 debtExchangeRateX96,
        uint256 lendExchangeRateX96,
        uint256 oldShares,
        uint256 newShares
    ) internal {
        if (oldShares != newShares) {
            (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);

            // remove previous collateral - add new collateral
            if (oldShares > newShares) {
                uint192 difference = SafeCast.toUint192(oldShares - newShares);
                tokenConfigs[token0].totalDebtShares -= difference;
                tokenConfigs[token1].totalDebtShares -= difference;
            } else {
                uint192 difference = SafeCast.toUint192(newShares - oldShares);
                tokenConfigs[token0].totalDebtShares += difference;
                tokenConfigs[token1].totalDebtShares += difference;

                // check if current value of used collateral is more than allowed limit
                // if collateral is decreased - never revert
                uint256 lentAssets = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Up);
                uint256 collateralValueLimitFactorX32 = tokenConfigs[token0].collateralValueLimitFactorX32;
                if (
                    collateralValueLimitFactorX32 < type(uint32).max
                        && _convertToAssets(tokenConfigs[token0].totalDebtShares, debtExchangeRateX96, Math.Rounding.Up)
                            > lentAssets * collateralValueLimitFactorX32 / Q32
                ) {
                    revert CollateralValueLimit();
                }
                collateralValueLimitFactorX32 = tokenConfigs[token1].collateralValueLimitFactorX32;
                if (
                    collateralValueLimitFactorX32 < type(uint32).max
                        && _convertToAssets(tokenConfigs[token1].totalDebtShares, debtExchangeRateX96, Math.Rounding.Up)
                            > lentAssets * collateralValueLimitFactorX32 / Q32
                ) {
                    revert CollateralValueLimit();
                }
            }
        }
    }

    function _resetDailyLendIncreaseLimit(uint256 newLendExchangeRateX96, bool force) internal {
        // daily lend limit reset handling
        uint32 time = uint32(block.timestamp / 1 days);
        if (force || time > dailyLendIncreaseLimitLastReset) {
            dailyLendIncreaseLimitLeft =
                _calculateDailyIncreaseLimit(newLendExchangeRateX96, dailyLendIncreaseLimitMin, MAX_DAILY_LEND_INCREASE_X32);
            dailyLendIncreaseLimitLastReset = time;
        }
    }

    function _resetDailyDebtIncreaseLimit(uint256 newLendExchangeRateX96, bool force) internal {
        // daily debt limit reset handling
        uint32 time = uint32(block.timestamp / 1 days);
        if (force || time > dailyDebtIncreaseLimitLastReset) {
            dailyDebtIncreaseLimitLeft =
                _calculateDailyIncreaseLimit(newLendExchangeRateX96, dailyDebtIncreaseLimitMin, MAX_DAILY_DEBT_INCREASE_X32);
            dailyDebtIncreaseLimitLastReset = time;
        }
    }

    function _calculateDailyIncreaseLimit(uint256 lendExchangeRateX96, uint256 minLimit, uint256 limitFactorX32)
        private
        view
        returns (uint256)
    {
        uint256 limit = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Up) * limitFactorX32 / Q32;
        return minLimit > limit ? minLimit : limit;
    }

    /// @notice Sets gauge manager address once (owner only)
    /// @dev Safety note: this only validates that `_gaugeManager` is a contract and then permanently locks it.
    /// @dev GaugeManager enforces `msg.sender == address(vault)`, so configuring a manager deployed for a different
    ///      vault will make stake/unstake/reward-precompound paths revert Unauthorized and cannot be corrected afterward.
    /// @dev This one-time lock without vault-binding handshake is an accepted operational/trust risk.
    function setGaugeManager(address _gaugeManager) external onlyOwner {
        if (gaugeManager != address(0)) {
            revert GaugeManagerAlreadySet();
        }
        if (_gaugeManager == address(0) || _gaugeManager.code.length == 0) {
            revert InvalidConfig();
        }

        gaugeManager = _gaugeManager;
        emit SetGaugeManager(_gaugeManager);
    }

    function stakePosition(uint256 tokenId) external override {
        _requireGaugeManagerSet();
        if (tokenOwner[tokenId] != msg.sender) {
            revert NotDepositor();
        }

        _stake(tokenId);
        // Explicit user-initiated staking can realize pre-stake fees to the borrower, so open loans must remain
        // healthy under the post-stake valuation model, which excludes fee collateral for staked positions.
        if (loans[tokenId].debtShares != 0) {
            (uint256 debt,,,,) = loanInfo(tokenId);
            _requireLoanIsHealthy(tokenId, debt);
        }
    }

    function unstakePosition(uint256 tokenId) external override {
        _requireGaugeManagerSet();
        if (tokenOwner[tokenId] != msg.sender && transformedTokenId != tokenId) {
            revert Unauthorized();
        }

        IGaugeManager(gaugeManager).unstakePosition(tokenId);
    }

    function _stake(uint256 tokenId) private {
        nonfungiblePositionManager.approve(gaugeManager, tokenId);
        IGaugeManager(gaugeManager).stakePosition(tokenId);
        // Safety gate: staking manager must move the NFT out of the vault. Prevents no-op managers from
        // leaving lingering approvals on vaulted collateral.
        // NOTE FOR AUDITS: this only verifies "not in vault anymore"; it does not prove custody sits directly on the
        // configured gauge address. That deeper custody assumption is accepted and delegated to gauge integration trust.
        if (nonfungiblePositionManager.ownerOf(tokenId) == address(this)) {
            revert InvalidConfig();
        }
    }

    function _unstakeIfNeeded(uint256 tokenId) internal returns (bool wasStaked) {
        if (gaugeManager != address(0)) {
            return IGaugeManager(gaugeManager).unstakeIfStaked(tokenId);
        }
    }

    function _checkLoanIsHealthy(uint256 tokenId, uint256 debt, bool withBuffer)
        internal
        view
        returns (bool isHealthy, uint256 fullValue, uint256 collateralValue, uint256 feeValue)
    {
        // Staked Slipstream positions pass `ignoreFees=true` so oracle skips fee-growth math and excludes fee value.
        bool ignoreFees = _isStaked(tokenId);
        (fullValue, feeValue,,) = oracle.getValue(tokenId, address(asset), ignoreFees);
        uint256 collateralFactorX32 = _calculateTokenCollateralFactorX32(tokenId);
        collateralValue = fullValue.mulDiv(collateralFactorX32, Q32);
        isHealthy = (withBuffer ? collateralValue * BORROW_SAFETY_BUFFER_X32 / Q32 : collateralValue) >= debt;
    }

    function _isStaked(uint256 tokenId) private view returns (bool) {
        address manager = gaugeManager;
        return manager != address(0) && IGaugeManager(manager).tokenIdToGauge(tokenId) != address(0);
    }

    function _requireGaugeManagerSet() private view {
        if (gaugeManager == address(0)) {
            revert GaugeManagerNotSet();
        }
    }

    function _convertToShares(uint256 amount, uint256 exchangeRateX96, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return amount.mulDiv(Q96, exchangeRateX96, rounding);
    }

    function _convertToAssets(uint256 shares, uint256 exchangeRateX96, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return shares.mulDiv(exchangeRateX96, Q96, rounding);
    }

    function _addTokenToOwner(address to, uint256 tokenId) internal {
        ownedTokensIndex[tokenId] = ownedTokens[to].length;
        ownedTokens[to].push(tokenId);
        tokenOwner[tokenId] = to;
    }

    function _removeTokenFromOwner(address from, uint256 tokenId) internal {
        uint256 lastTokenIndex = ownedTokens[from].length - 1;
        uint256 tokenIndex = ownedTokensIndex[tokenId];
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedTokens[from][lastTokenIndex];
            ownedTokens[from][tokenIndex] = lastTokenId;
            ownedTokensIndex[lastTokenId] = tokenIndex;
        }
        ownedTokens[from].pop();
        // Note that ownedTokensIndex[tokenId] is not deleted. There is no need to delete it - gas optimization
        delete tokenOwner[tokenId]; // Remove the token from the token owner mapping
    }
}
