// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IBTCStaking
 * @dev Interface for Core's Bitcoin staking mechanism using lstBTC tokens
 */
interface IBTCStaking {
    /**
     * @notice Stake BTC and receive lstBTC tokens
     * @param amount The amount of BTC to stake
     * @return The amount of lstBTC received
     */
    function stake(uint256 amount) external returns (uint256);

    /**
     * @notice Unstake lstBTC tokens and receive BTC back
     * @param lstBTCAmount The amount of lstBTC to redeem
     * @return The amount of BTC returned
     */
    function unstake(uint256 lstBTCAmount) external returns (uint256);

    /**
     * @notice View pending staking rewards for a user
     * @param user The address of the user
     * @return The amount of rewards earned
     */
    function getStakingRewards(address user) external view returns (uint256);

    /**
     * @notice Claim available staking rewards for a user
     * @param user The address of the user
     * @return The amount of rewards claimed
     */
    function claimRewards(address user) external returns (uint256);

    /**
     * @notice Get the lstBTC balance of a user
     * @param user The address of the user
     * @return The lstBTC balance
     */
    function getLstBTCBalance(address user) external view returns (uint256);
}
