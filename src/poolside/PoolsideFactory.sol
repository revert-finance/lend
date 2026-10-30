// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./PoolsidePosition.sol";
import "../interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";

/// @notice DRAFT: create a fresh position and configure staking + AutoExit in one transaction.
/// @dev No administrator, upgrades, arbitrary calls or shared user-reward balances. One-time prerequisite:
/// AutoExit's owner must register THIS factory as an operator. Existing operators then call executeExit.
contract PoolsideFactory is ReentrancyGuard, IPoolsideRegistry {
    using SafeERC20 for IERC20;

    V3Utils public immutable utils;
    V3Vault public immutable vault;
    GaugeManager public immutable manager;
    AutoRangeAndCompound public immutable automation;
    AutoExit public immutable autoExit;
    INonfungiblePositionManager public immutable npm;
    address public override creatingHolder;

    // History is retained for reward recovery. activeHolder() is the active-management source of truth.
    mapping(uint256 => PoolsidePosition) public positions;

    error InvalidBinding();
    error InvalidMint();
    error UnsupportedToken();
    error Unauthorized();

    event PositionCreated(uint256 indexed tokenId, address indexed holder, address indexed beneficiary);
    event PositionRemoved(uint256 indexed tokenId, address indexed holder, address indexed beneficiary);

    constructor(V3Utils _utils, V3Vault _vault, AutoRangeAndCompound _automation, AutoExit _autoExit) {
        utils = _utils;
        vault = _vault;
        automation = _automation;
        autoExit = _autoExit;
        INonfungiblePositionManager n = _utils.nonfungiblePositionManager();
        npm = n;
        GaugeManager m = GaugeManager(payable(_vault.gaugeManager()));
        manager = m;
        if (
            address(_vault.nonfungiblePositionManager()) != address(n)
                || address(_automation.nonfungiblePositionManager()) != address(n)
                || address(_autoExit.nonfungiblePositionManager()) != address(n)
                || address(m.nonfungiblePositionManager()) != address(n) || address(m.vault()) != address(_vault)
                || m.compoundModeSource() != address(_automation) || !_automation.vaults(address(_vault))
                || !_vault.transformerAllowList(address(_automation))
        ) revert InvalidBinding();
    }

    /// @notice ERC20 inputs require existing approvals to this factory. ETH may fund the WETH side directly.
    /// @dev Beneficiary is ALWAYS msg.sender. Recipient fields are overwritten; third-token swaps are excluded.
    /// Swap data is interpreted only by the immutable V3Utils and its configured swap infrastructure.
    function create(
        V3Utils.SwapAndMintParams calldata requested,
        AutoExit.PositionConfig calldata exitConfig,
        bool initiallyStake
    ) external payable nonReentrant returns (uint256 tokenId, PoolsidePosition holder) {
        if (!autoExit.operators(address(this))) revert InvalidBinding();
        if (
            !exitConfig.isActive || requested.token0 == requested.token1
                || (requested.amount0 == 0 && requested.amount1 == 0)
                || (address(requested.swapSourceToken) != address(0)
                    && requested.swapSourceToken != requested.token0
                    && requested.swapSourceToken != requested.token1)
        ) {
            revert InvalidMint();
        }
        address pool = IAerodromeSlipstreamFactory(npm.factory())
            .getPool(address(requested.token0), address(requested.token1), int24(requested.fee));
        if (pool == address(0) || manager.poolToGauge(pool) == address(0)) revert InvalidBinding();

        uint256 native0;
        uint256 native1;
        if (msg.value != 0) {
            address wrapped = address(utils.weth());
            if (address(requested.token0) == wrapped && msg.value <= requested.amount0) native0 = msg.value;
            else if (address(requested.token1) == wrapped && msg.value <= requested.amount1) native1 = msg.value;
            else revert InvalidMint();
        }
        holder =
            new PoolsidePosition(msg.sender, PoolsidePosition.Bindings(utils, vault, manager, automation, autoExit));
        _fund(requested.token0, requested.amount0 - native0);
        _fund(requested.token1, requested.amount1 - native1);
        V3Utils.SwapAndMintParams memory params = requested;
        // V3Utils unwraps native-funded WETH leftovers. The holder accepts ETH and refunds WETH to any beneficiary.
        params.recipient = msg.value == 0 ? msg.sender : address(holder);
        params.recipientNFT = address(holder);
        params.returnData = "";
        creatingHolder = address(holder);
        uint128 liquidity;
        (tokenId, liquidity,,) = utils.swapAndMint{value: msg.value}(params);
        creatingHolder = address(0);
        requested.token0.forceApprove(address(utils), 0);
        requested.token1.forceApprove(address(utils), 0);
        if (liquidity == 0 || address(positions[tokenId]) != address(0) || holder.tokenId() != tokenId) {
            revert InvalidMint();
        }
        positions[tokenId] = holder;
        holder.initialize(tokenId, exitConfig, initiallyStake);
        emit PositionCreated(tokenId, address(holder), msg.sender);
    }

    function _fund(IERC20 token, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnsupportedToken();
        token.forceApprove(address(utils), amount);
    }

    /// @notice Executes the user's existing exit rule, with all custody transitions in one atomic transaction.
    /// @dev No recipient override. A failed trigger, swap or payout restores the original position and registry.
    function executeExit(AutoExit.ExecuteParams calldata params) external nonReentrant {
        if (!autoExit.operators(msg.sender)) revert Unauthorized();
        PoolsidePosition holder = positions[params.tokenId];
        if (address(holder) == address(0) || !holder.active()) revert InvalidMint();
        holder.prepareAutoExit();
        autoExit.execute(params);
        holder.finishAutoExit();
    }

    function activeHolder(uint256 tokenId) external view returns (address) {
        PoolsidePosition holder = positions[tokenId];
        return address(holder) != address(0) && holder.active() ? address(holder) : address(0);
    }

    function positionClosed(uint256 tokenId) external override {
        PoolsidePosition holder = positions[tokenId];
        if (
            address(holder) == address(0) || msg.sender != address(holder)
                || holder.state() != PoolsidePosition.State.Closed
        ) revert Unauthorized();
        emit PositionRemoved(tokenId, address(holder), holder.beneficiary());
    }
}
