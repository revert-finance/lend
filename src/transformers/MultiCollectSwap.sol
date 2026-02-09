// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../utils/Swapper.sol";
import "./Transformer.sol";

/// @title MultiCollectSwap
/// @notice Utility contract that collects fees from multiple Uniswap V3 NFT positions,
/// executes swaps to convert collected tokens to a destination token, and sends all resulting tokens to the caller.
contract MultiCollectSwap is Transformer, Swapper {
    /// @notice Emitted when fees are collected and optionally swapped
    /// @param owner The address that initiated the operation
    /// @param recipient The address that received the output tokens
    /// @param tokenIds The token IDs that were processed
    event MultiCollectAndSwap(address indexed owner, address indexed recipient, uint256[] tokenIds);

    /// @notice Parameters for the execute function
    /// @param tokenIds NFTs to collect fees from (mixed vault/non-vault)
    /// @param swaps Swaps to execute (0x or UniversalRouter)
    /// @param outputToken Single token to transfer to recipient at end
    /// @param recipient Where to send output token
    struct ExecuteParams {
        uint256[] tokenIds;
        RouterSwapParams[] swaps;
        address outputToken;
        address recipient;
    }

    /// @notice Constructor
    /// @param _nonfungiblePositionManager Uniswap v3 position manager
    /// @param _universalRouter Uniswap Universal Router
    /// @param _zeroxAllowanceHolder 0x Protocol AllowanceHolder contract
    constructor(
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Swapper(_nonfungiblePositionManager, _universalRouter, _zeroxAllowanceHolder) {}

    /// @notice Main entry point - collects fees from positions, executes swaps, and sends output to recipient
    /// @dev Each position's tokens must either be the outputToken or have a corresponding swap.
    /// @param params Execute parameters including tokenIds, swaps, outputToken, and recipient
    function execute(ExecuteParams calldata params) external {
        uint256 length = params.tokenIds.length;
        address recipient = params.recipient;
        address outputToken = params.outputToken;

        // Collect fees from all positions (with validation)
        for (uint256 i; i < length;) {
            uint256 tokenId = params.tokenIds[i];
            (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);

            // Validate that position tokens are covered by outputToken or swaps that produce outputToken
            if (token0 != outputToken && !_swapExists(params.swaps, token0, outputToken)) {
                revert InvalidConfig();
            }
            if (token1 != outputToken && !_swapExists(params.swaps, token1, outputToken)) {
                revert InvalidConfig();
            }

            address owner = nonfungiblePositionManager.ownerOf(tokenId);
            if (vaults[owner]) {
                // Vault-held - validate caller is the vault position owner before calling transform
                if (IVault(owner).ownerOf(tokenId) != msg.sender) {
                    revert Unauthorized();
                }
                IVault(owner).transform(tokenId, address(this), abi.encodeCall(this.collect, (tokenId)));
            } else {
                // Direct ownership - validate and collect
                if (owner != msg.sender) {
                    revert Unauthorized();
                }
                nonfungiblePositionManager.collect(
                    INonfungiblePositionManager.CollectParams(
                        tokenId, address(this), type(uint128).max, type(uint128).max
                    )
                );
            }
            unchecked {
                ++i;
            }
        }

        // Execute swaps
        length = params.swaps.length;
        for (uint256 i; i < length;) {
            _routerSwap(params.swaps[i]);
            unchecked {
                ++i;
            }
        }

        // Transfer output token balance to recipient
        uint256 balance = IERC20(outputToken).balanceOf(address(this));
        if (balance > 0) {
            SafeERC20.safeTransfer(IERC20(outputToken), recipient, balance);
        }

        // Transfer any leftover swap input tokens to recipient (from partial swaps or rounding)
        for (uint256 i; i < length;) {
            address tokenIn = address(params.swaps[i].tokenIn);
            if (tokenIn != outputToken) {
                uint256 leftover = IERC20(tokenIn).balanceOf(address(this));
                if (leftover > 0) {
                    SafeERC20.safeTransfer(IERC20(tokenIn), recipient, leftover);
                }
            }
            unchecked {
                ++i;
            }
        }

        emit MultiCollectAndSwap(msg.sender, recipient, params.tokenIds);
    }

    /// @dev Returns true if an executable swap exists that converts token to outputToken
    function _swapExists(RouterSwapParams[] calldata swaps, address token, address outputToken) internal pure returns (bool) {
        uint256 length = swaps.length;
        for (uint256 i; i < length;) {
            if (address(swaps[i].tokenIn) == token && address(swaps[i].tokenOut) == outputToken && swaps[i].amountIn > 0 && swaps[i].swapData.length > 0) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @notice Called by vault via transform() for vault-held positions
    /// @param tokenId The token ID to collect fees from
    function collect(uint256 tokenId) external {
        _validateCaller(nonfungiblePositionManager, tokenId);
        nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)
        );
    }
}
