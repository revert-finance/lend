// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IModule.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-periphery/interfaces/ISwapRouter.sol";

interface ICompoundorModule is IModule {
   
    // config changes
    event RewardUpdated(address account, uint64 totalRewardX64, uint64 compounderRewardX64);
    event TWAPConfigUpdated(address account, uint32 maxTWAPTickDifference, uint32 TWAPSeconds);

    // balance movements
    event BalanceAdded(address account, address token, uint256 amount);
    event BalanceRemoved(address account, address token, uint256 amount);
    event BalanceWithdrawn(address account, address token, address to, uint256 amount);

    // autocompound event
    event AutoCompounded(
        address account,
        uint256 tokenId,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1
    );

    /// @notice The weth address
    function weth() external view returns (address);

    /// @notice The factory address with which this staking contract is compatible
    function factory() external view returns (IUniswapV3Factory);

    /// @notice The nonfungible position manager address with which this staking contract is compatible
    function nonfungiblePositionManager() external view returns (INonfungiblePositionManager);

    /// @notice The nonfungible position manager address with which this staking contract is compatible
    function swapRouter() external view returns (ISwapRouter);

    /// @notice Total reward which is payed for autocompounding
    function totalRewardX64() external view returns (uint64);

    /// @notice Reward which is payed to compounder - less or equal to totalRewardX64
    function compounderRewardX64() external view returns (uint64);

    /// @notice Max tick difference between TWAP tick and current price to allow operations
    function maxTWAPTickDifference() external view returns (uint32);

    /// @notice Number of seconds to use for TWAP calculation
    function TWAPSeconds() external view returns (uint32);

    /**
     * @notice Management method to lower reward or change ratio between total and compounder reward (onlyOwner)
     * @param _totalRewardX64 new total reward (can't be higher than current total reward)
     * @param _compounderRewardX64 new compounder reward
     */
    function setReward(uint64 _totalRewardX64, uint64 _compounderRewardX64) external;

    /**
     * @notice Management method to change the max tick difference from twap to allow swaps (onlyOwner)
     * @param _maxTWAPTickDifference new max tick difference
     * @param _TWAPSeconds new TWAP period seconds
     */
    function setTWAPConfig(uint32 _maxTWAPTickDifference, uint32 _TWAPSeconds) external;

    /**
     * @notice Returns balance of token of account
     * @param account Address of account
     * @param token Address of token
     * @return balance amount of token for account
     */
    function accountBalances(address account, address token) external view returns (uint256 balance);

    /**
     * @notice Withdraws token balance for a address and token
     * @param token Address of token to withdraw
     * @param to Address to send to
     * @param amount amount to withdraw
     */
    function withdrawBalance(address token, address to, uint256 amount) external;

    /// @notice how reward should be converted
    enum RewardConversion { NONE, TOKEN_0, TOKEN_1 }

    /// @notice params for autoCompound()
    struct AutoCompoundParams {
        // tokenid to autocompound
        uint256 tokenId;
        
        // which token to convert to
        RewardConversion rewardConversion;

        // should token be withdrawn to compounder immediately
        bool withdrawReward;

        // do swap - to add max amount to position (costs more gas)
        bool doSwap;
    }

    /**
     * @notice Autocompounds for a given NFT (anyone can call this and gets a percentage of the fees)
     * @param params Autocompound specific parameters (tokenId, ...)
     * @return reward0 Amount of token0 caller recieves
     * @return reward1 Amount of token1 caller recieves
     * @return compounded0 Amount of token0 that was compounded
     * @return compounded1 Amount of token1 that was compounded
     */
    function autoCompound(AutoCompoundParams calldata params) external returns (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1);
}

error SwapNotAllowed();
error CollectInvalid();
error SwapFailed();
error SlippageError();