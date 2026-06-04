// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../interfaces/pancake/IPancakeMasterChefV3.sol";
import "../interfaces/pancake/IPancakeMasterChefV3Staker.sol";
import "../utils/Constants.sol";

/// @notice PancakeSwap V3 MasterChef custody contract for staked NFT positions.
/// @dev MasterChef records this contract as the position user. Logical ownership is tracked in positionOwners.
contract PancakeMasterChefV3Staker is
    Ownable2Step,
    Multicall,
    IERC721Receiver,
    ReentrancyGuard,
    Constants,
    IPancakeMasterChefV3Staker
{
    using SafeERC20 for IERC20;

    IERC20 public immutable cakeToken;
    IPancakeMasterChefV3 public immutable masterChef;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice Active original token id during a transform call.
    /// @dev Existing automators validate this value to confirm they are executing inside the staker.
    uint256 public override transformedTokenId;

    /// @notice Logical owner of each NFT managed by this staker.
    mapping(uint256 => address) public positionOwners;
    /// @notice Contracts allowed to transform positions.
    mapping(address => bool) public transformerAllowList;
    /// @notice Owner approvals for automators to call transform on a position.
    mapping(address => mapping(uint256 => mapping(address => bool))) public transformApprovals;

    uint256 private activeFinalTokenId;
    address private activeTransformer;

    error ZeroAddress();

    event SetTransformer(address indexed transformer, bool active);
    event ApprovedTransform(uint256 indexed tokenId, address indexed owner, address indexed target, bool active);
    event PositionStaked(uint256 indexed tokenId, address indexed owner, address indexed masterChef);
    event PositionRestaked(uint256 indexed tokenId, address indexed owner, address indexed masterChef);
    event PositionUnstaked(
        uint256 indexed tokenId, address indexed owner, address indexed recipient, uint256 cakeAmount
    );
    event RewardsClaimed(uint256 indexed tokenId, address indexed owner, address indexed recipient, uint256 cakeAmount);
    event TransformExecuted(
        uint256 indexed tokenId,
        uint256 indexed finalTokenId,
        address indexed owner,
        address transformer,
        uint256 cakeAmount,
        bool rewardCompound
    );
    event LeftoverSent(uint256 indexed tokenId, address indexed token, address indexed to, uint256 amount);

    constructor(INonfungiblePositionManager npm, IPancakeMasterChefV3 _masterChef, IERC20 _cakeToken) {
        if (address(npm) == address(0) || address(_masterChef) == address(0) || address(_cakeToken) == address(0)) {
            revert InvalidConfig();
        }
        if (_masterChef.CAKE() != address(_cakeToken) || _masterChef.nonfungiblePositionManager() != address(npm)) {
            revert InvalidConfig();
        }

        nonfungiblePositionManager = npm;
        masterChef = _masterChef;
        cakeToken = _cakeToken;
    }

    /// @notice Returns the logical owner recorded by this staker.
    function ownerOf(uint256 tokenId) external view override returns (address owner) {
        owner = positionOwners[tokenId];
    }

    /// @notice Returns the current ERC-721 custodian, or zero if the NFT no longer exists.
    function custodyOf(uint256 tokenId) external view override returns (address nftOwner) {
        nftOwner = _nftOwnerOrZero(tokenId);
    }

    /// @notice Returns true if the staker has logical ownership accounting for tokenId.
    function isManaged(uint256 tokenId) external view override returns (bool managed) {
        managed = positionOwners[tokenId] != address(0);
    }

    /// @notice Returns true if the managed NFT is currently held by MasterChefV3.
    function isStaked(uint256 tokenId) external view override returns (bool staked) {
        staked = positionOwners[tokenId] != address(0) && _nftOwnerOrZero(tokenId) == address(masterChef);
    }

    /// @notice Adds or removes a transformer accepted by this staker.
    function setTransformer(address transformer, bool active) external onlyOwner {
        if (
            transformer == address(0) || transformer == address(this) || transformer == address(masterChef)
                || transformer == address(nonfungiblePositionManager) || transformer == address(cakeToken)
        ) {
            revert InvalidConfig();
        }

        transformerAllowList[transformer] = active;
        emit SetTransformer(transformer, active);
    }

    /// @notice Allows an automator to transform a specific position for its owner.
    function approveTransform(uint256 tokenId, address target, bool active) external override {
        if (positionOwners[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        transformApprovals[msg.sender][tokenId][target] = active;
        emit ApprovedTransform(tokenId, msg.sender, target, active);
    }

    /// @notice Transfers a Pancake V3 NFT into this contract and stakes it into MasterChef for recipient.
    /// @dev Users may also call safeTransferFrom directly; this helper exists for explicit recipient selection.
    function stakePosition(uint256 tokenId, address recipient) external nonReentrant {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(recipient));
    }

    /// @notice Withdraws a managed position to recipient.
    /// @dev Non-empty local positions are restaked; only empty local residual positions can be transferred out.
    function unstakePosition(uint256 tokenId, address recipient) external nonReentrant returns (uint256 cakeAmount) {
        address owner = _requirePositionOwner(tokenId);
        if (recipient == address(0)) {
            recipient = owner;
        }

        address nftOwner = _nftOwnerOrZero(tokenId);
        if (nftOwner == address(masterChef)) {
            if (recipient == address(this)) {
                revert InvalidConfig();
            }
            delete positionOwners[tokenId];
            cakeAmount = masterChef.withdraw(tokenId, recipient);
            emit PositionUnstaked(tokenId, owner, recipient, cakeAmount);
            return cakeAmount;
        }
        if (nftOwner != address(this)) {
            revert NotConfigured();
        }
        if (_positionLiquidity(tokenId) != 0) {
            _stakeFromStaker(tokenId);
            emit PositionRestaked(tokenId, owner, address(masterChef));
            return 0;
        }

        delete positionOwners[tokenId];
        nonfungiblePositionManager.safeTransferFrom(address(this), recipient, tokenId);
        emit PositionUnstaked(tokenId, owner, recipient, cakeAmount);
    }

    /// @notice Harvests CAKE rewards for a staked position to recipient.
    function claimRewards(uint256 tokenId, address recipient) external nonReentrant returns (uint256 cakeAmount) {
        address owner = _requireStakedOwnerCaller(tokenId);
        if (recipient == address(0)) {
            recipient = owner;
        }

        cakeAmount = masterChef.harvest(tokenId, recipient);
        emit RewardsClaimed(tokenId, owner, recipient, cakeAmount);
    }

    /// @notice Temporarily withdraws a staked NFT, calls a transformer, then restakes non-empty results.
    /// @dev CAKE harvested by MasterChef withdrawal is sent to the logical owner before the transformer runs.
    function transform(uint256 tokenId, address transformer, bytes calldata data)
        external
        override
        nonReentrant
        returns (uint256 newTokenId)
    {
        newTokenId = _transform(tokenId, transformer, data, false);
    }

    /// @notice Transform variant that hands harvested CAKE to the transformer for reward compounding.
    /// @dev The transformer must implement IPancakeMasterChefV3RewardTransformer.
    function transformWithRewardCompound(uint256 tokenId, address transformer, bytes calldata data)
        external
        override
        nonReentrant
        returns (uint256 newTokenId)
    {
        newTokenId = _transform(tokenId, transformer, data, true);
    }

    /// @notice Semantic alias for reward compounding through an approved transformer.
    /// @dev Uses the same authorization and custody path as transformWithRewardCompound.
    function compoundRewards(uint256 tokenId, address transformer, bytes calldata data)
        external
        override
        nonReentrant
        returns (uint256 newTokenId)
    {
        newTokenId = _transform(tokenId, transformer, data, true);
    }

    function _transform(uint256 tokenId, address transformer, bytes calldata data, bool rewardCompound)
        internal
        returns (uint256 newTokenId)
    {
        if (tokenId == 0 || !transformerAllowList[transformer]) {
            revert TransformNotAllowed();
        }
        if (transformedTokenId != 0) {
            revert Reentrancy();
        }

        address owner = _requireStakedPosition(tokenId);
        if (msg.sender != owner) {
            if (msg.sender != transformer || !transformApprovals[owner][tokenId][msg.sender]) {
                revert Unauthorized();
            }
        }

        transformedTokenId = tokenId;
        activeFinalTokenId = tokenId;
        activeTransformer = transformer;

        (address token0, address token1) = _positionTokens(tokenId);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        uint256 cakeBalanceBefore = cakeToken.balanceOf(address(this));

        uint256 cakeAmount = _withdrawToSelf(tokenId);
        if (rewardCompound) {
            if (cakeAmount != 0) {
                cakeToken.safeTransfer(transformer, cakeAmount);
            }
        } else if (cakeAmount != 0) {
            cakeToken.safeTransfer(owner, cakeAmount);
        }

        nonfungiblePositionManager.approve(transformer, tokenId);

        if (rewardCompound) {
            IPancakeMasterChefV3RewardTransformer(transformer).executeWithReward(tokenId, owner, cakeAmount, data);
        } else {
            _callTransformer(transformer, data);
        }

        newTokenId = activeFinalTokenId == 0 ? tokenId : activeFinalTokenId;
        if (positionOwners[newTokenId] != owner) {
            revert Unauthorized();
        }

        transformedTokenId = 0;
        activeFinalTokenId = 0;
        activeTransformer = address(0);

        _finalizeTransformPosition(tokenId);
        _sweepTransformTokenIncreases(tokenId, owner, token0, token1, balance0Before, balance1Before, cakeBalanceBefore);

        emit TransformExecuted(tokenId, newTokenId, owner, transformer, cakeAmount, rewardCompound);
    }

    function _callTransformer(address transformer, bytes calldata data) internal {
        (bool success, bytes memory revertData) = transformer.call(data);
        if (success) {
            return;
        }
        if (revertData.length == 0) {
            revert TransformFailed();
        }
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    function _requirePositionOwner(uint256 tokenId) internal view returns (address owner) {
        owner = positionOwners[tokenId];
        if (owner == address(0)) {
            revert NotConfigured();
        }
        if (msg.sender != owner) {
            revert Unauthorized();
        }
    }

    function _requireStakedPosition(uint256 tokenId) internal view returns (address owner) {
        owner = positionOwners[tokenId];
        if (owner == address(0)) {
            revert NotConfigured();
        }
        if (_nftOwnerOrZero(tokenId) != address(masterChef)) {
            revert NotConfigured();
        }
    }

    function _requireStakedOwnerCaller(uint256 tokenId) internal view returns (address owner) {
        owner = _requireStakedPosition(tokenId);
        if (msg.sender != owner) {
            revert Unauthorized();
        }
    }

    function _positionTokens(uint256 tokenId) internal view returns (address token0, address token1) {
        (,, token0, token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
    }

    function _positionLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
    }

    function _stakeFromStaker(uint256 tokenId) internal {
        nonfungiblePositionManager.safeTransferFrom(address(this), address(masterChef), tokenId);
        if (nonfungiblePositionManager.ownerOf(tokenId) != address(masterChef)) {
            revert InvalidConfig();
        }
    }

    function _withdrawToSelf(uint256 tokenId) internal returns (uint256 cakeAmount) {
        cakeAmount = masterChef.withdraw(tokenId, address(this));
    }

    function _finalizeTransformPosition(uint256 tokenId) internal {
        address nftOwner = _nftOwnerOrZero(tokenId);
        if (nftOwner == address(masterChef)) {
            return;
        }
        if (nftOwner != address(this)) {
            revert Unauthorized();
        }

        nonfungiblePositionManager.approve(address(0), tokenId);
        if (_positionLiquidity(tokenId) != 0) {
            address owner = positionOwners[tokenId];
            _stakeFromStaker(tokenId);
            emit PositionRestaked(tokenId, owner, address(masterChef));
        }
    }

    function _sweepTransformTokenIncreases(
        uint256 tokenId,
        address owner,
        address token0,
        address token1,
        uint256 balance0Before,
        uint256 balance1Before,
        uint256 cakeBalanceBefore
    ) internal {
        _sendBalanceIncrease(tokenId, token0, owner, balance0Before);
        if (token1 != token0) {
            _sendBalanceIncrease(tokenId, token1, owner, balance1Before);
        }
        if (address(cakeToken) != token0 && address(cakeToken) != token1) {
            _sendBalanceIncrease(tokenId, address(cakeToken), owner, cakeBalanceBefore);
        }
    }

    function _sendBalanceIncrease(uint256 tokenId, address token, address owner, uint256 balanceBefore) internal {
        uint256 amount = _balanceIncrease(token, balanceBefore);
        if (amount != 0) {
            IERC20(token).safeTransfer(owner, amount);
            emit LeftoverSent(tokenId, token, owner, amount);
        }
    }

    function _balanceIncrease(address token, uint256 balanceBefore) internal view returns (uint256 amount) {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore) {
            revert InsufficientLiquidity();
        }
        amount = balanceAfter - balanceBefore;
    }

    function _nftOwnerOrZero(uint256 tokenId) internal view returns (address nftOwner) {
        try nonfungiblePositionManager.ownerOf(tokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            nftOwner = address(0);
        }
    }

    /// @notice Receives Pancake V3 NFTs for deposits, MasterChef withdrawals, and transform-created positions.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }

        uint256 currentTransformedTokenId = transformedTokenId;
        if (currentTransformedTokenId != 0) {
            if (from == address(masterChef)) {
                if (tokenId != currentTransformedTokenId || positionOwners[tokenId] == address(0)) {
                    revert Unauthorized();
                }
                activeFinalTokenId = tokenId;
                return IERC721Receiver.onERC721Received.selector;
            }

            address transformOwner = positionOwners[currentTransformedTokenId];
            address existingOwner = positionOwners[tokenId];
            if (transformOwner == address(0) || (existingOwner != address(0) && existingOwner != transformOwner)) {
                revert Unauthorized();
            }

            if (existingOwner == address(0)) {
                positionOwners[tokenId] = transformOwner;
            }
            if (
                tokenId != currentTransformedTokenId && activeTransformer != address(0)
                    && transformApprovals[transformOwner][currentTransformedTokenId][activeTransformer]
            ) {
                transformApprovals[transformOwner][tokenId][activeTransformer] = true;
            }

            activeFinalTokenId = tokenId;
            if (_positionLiquidity(tokenId) != 0) {
                _stakeFromStaker(tokenId);
                emit PositionRestaked(tokenId, transformOwner, address(masterChef));
            }
            return IERC721Receiver.onERC721Received.selector;
        }

        if (positionOwners[tokenId] != address(0) || from == address(0) || from == address(masterChef)) {
            revert Unauthorized();
        }

        address owner = from;
        if (data.length != 0) {
            owner = abi.decode(data, (address));
        }
        if (owner == address(0)) {
            revert ZeroAddress();
        }

        positionOwners[tokenId] = owner;
        _stakeFromStaker(tokenId);
        emit PositionStaked(tokenId, owner, address(masterChef));
        return IERC721Receiver.onERC721Received.selector;
    }
}
