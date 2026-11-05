// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../V3Vault.sol";
import "../GaugeManager.sol";
import "../transformers/V3Utils.sol";
import "../transformers/AutoRangeAndCompound.sol";
import "../automators/AutoExit.sol";

interface IPoolsideRegistry {
    function creatingHolder() external view returns (address);
    function positionClosed(uint256 tokenId) external;
}

/// @notice DRAFT: one non-transferable beneficiary, one freshly minted NFT, no borrowing.
/// @dev The vault and GaugeManager see this address as owner. A separate address per position also isolates
/// rewards that GaugeManager aggregates by owner rather than tokenId. Closed holders remain usable for claims.
contract PoolsidePosition is IERC721Receiver, ReentrancyGuard, Swapper {
    using SafeERC20 for IERC20;

    enum State {
        AwaitingMint,
        Initializing,
        Active,
        Exiting,
        Closed
    }

    struct Bindings {
        V3Utils utils;
        V3Vault vault;
        GaugeManager manager;
        AutoRangeAndCompound automation;
        AutoExit autoExit;
    }

    IPoolsideRegistry public immutable registry;
    address public immutable beneficiary;
    INonfungiblePositionManager public immutable npm;
    V3Utils public immutable utils;
    V3Vault public immutable vault;
    GaugeManager public immutable manager;
    AutoRangeAndCompound public immutable automation;
    AutoExit public immutable autoExit;

    // Only an in-flight, holder-initiated swap may spend holder funds through a pool callback.
    address private settlementPool;
    IERC20 private settlementInput;
    uint256 private settlementAmount;

    State public state;
    uint256 public tokenId;
    IERC20 public token0;
    IERC20 public token1;
    bool public autoExitEnabled;

    error InvalidState();
    error InvalidNFT();
    error InsidePenaltyWindow();
    error InsufficientAssets();
    error UnspentRouterInput();

    event StakingManagementChanged(bool enabled);
    event AutoExitChanged(bool enabled);
    event Withdrawn(uint256 indexed tokenId, address indexed beneficiary, bool automated);
    event TokensClaimed(address indexed token, uint256 amount);
    event UnconvertedBalance(address indexed token, uint256 amount);
    event AssetSettled(address indexed beneficiary, uint256 amount);

    constructor(address _beneficiary, Bindings memory bindings)
        Swapper(
            bindings.utils.nonfungiblePositionManager(),
            bindings.utils.universalRouter(),
            bindings.utils.zeroxAllowanceHolder()
        )
    {
        require(_beneficiary != address(0), "zero beneficiary");
        registry = IPoolsideRegistry(msg.sender);
        beneficiary = _beneficiary;
        utils = bindings.utils;
        vault = bindings.vault;
        manager = bindings.manager;
        automation = bindings.automation;
        autoExit = bindings.autoExit;
        npm = bindings.utils.nonfungiblePositionManager();
    }

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert Unauthorized();
        _;
    }

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) revert Unauthorized();
        _;
    }

    receive() external payable {}

    /// @dev No arbitrary NFT imports. Initialization must be inside the registry's mint transaction.
    /// This callback is deliberately not nonReentrant: vault.remove calls it during guarded withdrawal.
    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(npm)) revert InvalidNFT();
        if (
            state == State.AwaitingMint && tokenId == 0 && from == address(utils)
                && registry.creatingHolder() == address(this)
        ) {
            if (id == 0) revert InvalidNFT();
            tokenId = id;
        } else if (state != State.Exiting || from != address(vault) || id != tokenId) {
            revert InvalidNFT();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function initialize(uint256 id, AutoExit.PositionConfig calldata exitConfig, bool initiallyStake)
        external
        nonReentrant
        onlyRegistry
    {
        if (state != State.AwaitingMint || id == 0 || id != tokenId || npm.ownerOf(id) != address(this)) {
            revert InvalidState();
        }
        state = State.Initializing;
        (,, address t0, address t1,,,,,,,,) = npm.positions(id);
        token0 = IERC20(t0);
        token1 = IERC20(t1);
        // Settle native-funded mint leftovers before staking can deliver separate rewards/fees.
        // The beneficiary may be a contract that cannot receive native ETH.
        _claimNative();
        _claimToken(token0);
        _claimToken(token1);
        // Configure while this contract directly owns the NFT. No standing ERC721 approval is needed.
        autoExit.configToken(id, exitConfig);
        npm.safeTransferFrom(address(this), address(vault), id, abi.encode(address(this)));
        vault.approveTransform(id, address(automation), true);
        // Poolside uses Simple fees and reinvests into the SAME NFT/range.
        // Equal range deltas keep automatic range changes disabled.
        AutoRangeAndCompound.PositionConfig memory config;
        config.autoCompound = true;
        config.onlyFees = true;
        // Allow up to 1% execution slippage for automatic fee compounding in either direction.
        config.token0SlippageX64 = uint64((uint256(1) << 64) / 100);
        config.token1SlippageX64 = config.token0SlippageX64;
        automation.configToken(id, address(vault), config, AutoRangeAndCompound.CompoundMode.Simple);
        automation.configStakingManagement(id, address(vault), true);
        if (initiallyStake) vault.stakePosition(id);
        autoExitEnabled = true;
        state = State.Active;
        emit StakingManagementChanged(true);
        emit AutoExitChanged(true);
    }

    function active() external view returns (bool) {
        return state == State.Active;
    }

    function setStakingManagement(bool enabled) external nonReentrant onlyBeneficiary {
        if (state != State.Active) revert InvalidState();
        automation.configStakingManagement(tokenId, address(vault), enabled);
        emit StakingManagementChanged(enabled);
    }

    /// @notice Pause/resume the originally selected exit rule without removing the position.
    function setAutoExitEnabled(bool enabled) external nonReentrant onlyBeneficiary {
        if (state != State.Active) revert InvalidState();
        autoExitEnabled = enabled;
        emit AutoExitChanged(enabled);
    }

    /// @notice User escape path: no keeper authorization or price-trigger requirement.
    /// Immediate/deferred rewards are separately claimable; reward redemption is never required here.
    function withdraw() external {
        withdrawTo(beneficiary);
    }

    /// @notice Only the beneficiary may choose another NFT recipient; reward ownership is unchanged.
    function withdrawTo(address recipient) public nonReentrant onlyBeneficiary {
        _prepareExit();
        _finishExit(false);
        npm.safeTransferFrom(address(this), recipient, tokenId);
    }

    /// @notice Close the entire position into the vault asset (USDC on Base), paid only to the beneficiary.
    /// @dev Caller supplies swap quotes/minima/deadline; action, asset, liquidity and recipient are fixed here.
    /// Available balances are returned too; deferred rewards and the empty NFT remain separately claimable.
    function withdrawToAsset(V3Utils.Instructions memory instructions, uint256 minAssets)
        external
        nonReentrant
        onlyBeneficiary
        returns (uint256 assets)
    {
        _prepareExit();
        IERC20 asset = IERC20(vault.asset());
        uint256 beforeBalance = asset.balanceOf(address(this));
        instructions.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        instructions.targetToken = address(asset);
        (,,,,,,, instructions.liquidity,,,,) = npm.positions(tokenId);
        instructions.feeAmount0 = type(uint128).max;
        instructions.feeAmount1 = type(uint128).max;
        instructions.recipient = address(this);
        instructions.unwrap = false;
        npm.approve(address(utils), tokenId);
        address router = utils.universalRouter();
        uint256 routerBalance0 = token0.balanceOf(router);
        uint256 routerBalance1 = token1.balanceOf(router);
        utils.execute(tokenId, instructions);
        // V3Utils prepays Universal Router: quotes must consume or refund the supplied input.
        if (token0.balanceOf(router) > routerBalance0 || token1.balanceOf(router) > routerBalance1) {
            revert UnspentRouterInput();
        }
        assets = asset.balanceOf(address(this));
        if (assets - beforeBalance < minAssets) revert InsufficientAssets();
        _finishExit(false);
        assets = _settleBalances();
    }

    /// @notice Retrieve the empty NFT retained after an asset exit or AutoExit independently of proceeds delivery.
    function claimNFT(address recipient) external nonReentrant onlyBeneficiary {
        if (state != State.Closed) revert InvalidState();
        npm.safeTransferFrom(address(this), recipient, tokenId);
    }

    /// @dev Registry completes preparation, AutoExit execution and settlement in ONE transaction.
    function prepareAutoExit() external nonReentrant onlyRegistry {
        if (!autoExitEnabled) revert InvalidState();
        // Agreed policy: automated exits and stake changes both wait out the current penalty window.
        // This may delay a price-triggered exit. The beneficiary's manual withdrawal is not subject to this guard.
        if (manager.tokenIdToGauge(tokenId) != address(0) && block.number < manager.penaltyWindowEnd(tokenId)) {
            revert InsidePenaltyWindow();
        }
        _prepareExit();
        npm.approve(address(autoExit), tokenId);
    }

    function finishAutoExit() external nonReentrant onlyRegistry {
        if (state != State.Exiting) revert InvalidState();
        _finishExit(true);
        _settleBalances();
    }

    /// @dev Each token's entire conversion is isolated. A missing route, dust, partial fill or unsafe price
    /// returns that token in kind instead of blocking principal exit. Deferred claims are not attempted here.
    function _settleBalances() private returns (uint256 assets) {
        if (address(this).balance != 0) weth.deposit{value: address(this).balance}();
        IERC20 asset = IERC20(vault.asset());
        _settleToken(token0, asset);
        _settleToken(token1, asset);
        _settleToken(IERC20(address(weth)), asset);
        _settleToken(manager.aeroToken(), asset);
        assets = asset.balanceOf(address(this));
        _claimToken(asset);
        emit AssetSettled(beneficiary, assets);
    }

    function _settleToken(IERC20 token, IERC20 asset) private {
        if (token == asset || token.balanceOf(address(this)) == 0) return;
        try this.settleTokenToAsset(token) {}
        catch {
            emit UnconvertedBalance(address(token), token.balanceOf(address(this)));
        }
        _claimToken(token);
    }

    /// @notice Internal atomic conversion boundary; neither operators nor beneficiaries may call directly.
    /// No arbitrary routes, calldata, recipients, approvals or per-call price limits are accepted.
    function settleTokenToAsset(IERC20 token) external {
        if (msg.sender != address(this)) revert Unauthorized();
        IERC20 asset = IERC20(vault.asset());
        if ((token == token0 && asset == token1) || (token == token1 && asset == token0)) {
            (,,,, uint24 spacing,,,,,,,) = npm.positions(tokenId);
            _settlementSwap(
                token,
                asset,
                address(_getPool(address(token0), address(token1), spacing)),
                token.balanceOf(address(this))
            );
        } else {
            IERC20 reward = manager.aeroToken();
            uint256 amount = token.balanceOf(address(this));
            if (token != reward) {
                amount = _settlementSwap(token, reward, manager.rewardBasePools(address(token)), amount);
            }
            if (reward != asset) _settlementSwap(reward, asset, manager.rewardBasePools(address(asset)), amount);
        }
    }

    function _settlementSwap(IERC20 input, IERC20 output, address poolAddress, uint256 amount)
        private
        returns (uint256 received)
    {
        if (poolAddress == address(0) || amount == 0 || amount > uint256(type(int256).max)) {
            revert InvalidPool();
        }
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        IERC20 t0 = IERC20(pool.token0());
        IERC20 t1 = IERC20(pool.token1());
        uint24 spacing = uint24(IAerodromeSlipstreamPool(poolAddress).tickSpacing());
        if (
            !((input == t0 && output == t1) || (input == t1 && output == t0))
                || address(_getPool(address(t0), address(t1), spacing)) != poolAddress
        ) revert InvalidPool();
        (uint160 price, int24 tick) = _getPoolSlot0(pool);
        // Reuse the existing exit TWAP policy; cap execution loss at 1% per hop (including pool fees).
        uint256 minimum = _validateSwap(
            input == t0,
            amount,
            pool,
            tick,
            price,
            autoExit.TWAPSeconds(),
            autoExit.maxTWAPTickDifference(),
            uint64(Q64 / 100)
        );
        if (minimum == 0) revert InsufficientAssets();
        uint256 beforeInput = input.balanceOf(address(this));
        uint256 beforeOutput = output.balanceOf(address(this));
        settlementPool = poolAddress;
        settlementInput = input;
        settlementAmount = amount;
        (uint256 spent,) = _poolSwap(PoolSwapParams(pool, t0, t1, spacing, input == t0, amount, minimum));
        settlementPool = address(0);
        settlementInput = IERC20(address(0));
        settlementAmount = 0;
        received = output.balanceOf(address(this)) - beforeOutput;
        if (spent != amount || beforeInput - input.balanceOf(address(this)) != amount || received < minimum) {
            revert SlippageError();
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        if (msg.sender != settlementPool || settlementPool == address(0)) revert Unauthorized();
        bool zeroForOne = address(settlementInput) == IUniswapV3Pool(msg.sender).token0();
        int256 owed = zeroForOne ? amount0Delta : amount1Delta;
        if (owed <= 0 || uint256(owed) > settlementAmount || (zeroForOne ? amount1Delta : amount0Delta) > 0) {
            revert InvalidConfig();
        }
        settlementPool = address(0); // A callback may pay once, and only up to the requested input.
        settlementInput.safeTransfer(msg.sender, uint256(owed));
    }

    function _prepareExit() private {
        if (state != State.Active) revert InvalidState();
        state = State.Exiting;
        automation.configStakingManagement(tokenId, address(vault), false);
        AutoRangeAndCompound.PositionConfig memory disabled;
        automation.configToken(tokenId, address(vault), disabled, AutoRangeAndCompound.CompoundMode.Simple);
        vault.approveTransform(tokenId, address(automation), false);
        // The holder exposes no borrow or generic transform function. Vault.remove independently checks no debt.
        vault.remove(tokenId, address(this), "");
    }

    function _finishExit(bool automated) private {
        // Clear the old rule even for a manual exit: a beneficiary may already globally approve AutoExit.
        AutoExit.PositionConfig memory disabled;
        autoExit.configToken(tokenId, disabled);
        npm.approve(address(0), tokenId);
        autoExitEnabled = false;
        state = State.Closed;
        registry.positionClosed(tokenId);
        emit Withdrawn(tokenId, beneficiary, automated);
    }

    /// @notice Claim asynchronous emissions, fees or accidental ERC20 transfers only to the fixed beneficiary.
    function claimTokens(IERC20[] calldata tokens) external nonReentrant onlyBeneficiary {
        _requireClaimable();
        for (uint256 i; i < tokens.length; ++i) {
            _claimToken(tokens[i]);
        }
    }

    function claimNative() external nonReentrant onlyBeneficiary {
        _requireClaimable();
        _claimNative();
    }

    function claimRewards() external nonReentrant onlyBeneficiary returns (uint256) {
        if (state != State.Active) revert InvalidState();
        return manager.claimRewards(tokenId, beneficiary);
    }

    function claimDeferredRewards(address gauge, uint256 batch)
        external
        nonReentrant
        onlyBeneficiary
        returns (uint256)
    {
        _requireClaimable();
        return manager.claimDeferredRewards(gauge, batch, beneficiary);
    }

    function claimRootDeferredRewards() external nonReentrant onlyBeneficiary returns (uint256) {
        _requireClaimable();
        return manager.claimRootDeferredRewards(beneficiary);
    }

    function _requireClaimable() private view {
        if (state != State.Active && state != State.Closed) revert InvalidState();
    }

    function _claimNative() private {
        uint256 amount = address(this).balance;
        if (amount != 0) weth.deposit{value: amount}();
        _claimToken(IERC20(address(weth)));
    }

    function _claimToken(IERC20 token) private {
        uint256 amount = token.balanceOf(address(this));
        if (amount != 0) {
            token.safeTransfer(beneficiary, amount);
            emit TokensClaimed(address(token), amount);
        }
    }
}
