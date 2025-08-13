// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IBTCStaking.sol";
import "../interfaces/ILstBTC.sol";

// PRICE FEED 0x48686EA995462d611F4DA0d65f90B21a30F259A5
//stCORE 0xd5Cb99b6f7AC35fB0A8071f7C700b45DA5556EbD
//MOCK BTC 0xF12D5E4D561000F1F464E4576bb27eA0e83931da
// BTCSTAKING 0xe7Bf8D39D8Cd29a65fBADD303619Efdfb988610e

/**
 * @title BTCStaking
 * @dev A mock implementation of the Bitcoin Staking mechanism for testing.
 * It simulates staking BTC (MockBTC) and minting lstBTC in return.
 * For simplicity, it uses a 1:1 ratio for staking/unstaking.
 */
contract BTCStaking is IBTCStaking, ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    ILstBTC public lstBTC;
    IERC20 public mockBTCToken; // Represents the wrapped BTC token

    // Mapping to track staked BTC and corresponding lstBTC for each user
    mapping(address => uint256) public userStakedBTC;
    mapping(address => uint256) public userMintedLstBTC;
    mapping(address => uint256) public userStakingRewards; // Accumulated rewards

    event BTCStaked(address indexed user, uint256 btcAmount, uint256 lstBTCAmount);
    event BTCUnstaked(address indexed user, uint256 lstBTCAmount, uint256 btcAmount);
    event RewardsClaimed(address indexed user, uint256 amount);

    constructor(address _lstBTC, address _mockBTCToken) Ownable(msg.sender) {
        lstBTC = ILstBTC(_lstBTC);
        mockBTCToken = IERC20(_mockBTCToken);
    }

    /**
     * @dev Stakes MockBTC and mints lstBTC.
     * For simplicity, assumes a 1:1 staking ratio.
     * This contract must be a minter for the lstBTC token.
     * @param amount The amount of MockBTC to stake.
     * @return lstBTCAmount The amount of lstBTC minted.
     */
    function stake(uint256 amount) external nonReentrant returns (uint256 lstBTCAmount) {
        require(amount > 0, "Amount must be greater than 0");

        uint256 contractBalance = mockBTCToken.balanceOf(address(this));
        uint256 allowance = mockBTCToken.allowance(msg.sender, address(this));

        if (allowance >= amount) {
            mockBTCToken.transferFrom(msg.sender, address(this), amount);
        } else {
            require(contractBalance >= amount, "Insufficient MockBTC balance in staking contract");
        }

        lstBTCAmount = amount;
        lstBTC.mint(msg.sender, lstBTCAmount);

        userStakedBTC[msg.sender] = userStakedBTC[msg.sender].add(amount);
        userMintedLstBTC[msg.sender] = userMintedLstBTC[msg.sender].add(lstBTCAmount);

        emit BTCStaked(msg.sender, amount, lstBTCAmount);
        return lstBTCAmount;
    }

    /**
     * @dev Unstakes lstBTC and returns MockBTC.
     * For simplicity, assumes a 1:1 unstaking ratio.
     * This contract must be able to burn lstBTC from the user.
     * @param lstBTCAmount The amount of lstBTC to unstake.
     * @return btcAmount The amount of MockBTC returned.
     */
    function unstake(uint256 lstBTCAmount) external nonReentrant returns (uint256 btcAmount) {
        require(lstBTCAmount > 0, "Amount must be greater than 0");
        require(userMintedLstBTC[msg.sender] >= lstBTCAmount, "Insufficient lstBTC staked");

        btcAmount = lstBTCAmount;
        require(mockBTCToken.balanceOf(address(this)) >= btcAmount, "Insufficient MockBTC in staking pool");

        lstBTC.burn(msg.sender, lstBTCAmount);
        mockBTCToken.transfer(msg.sender, btcAmount);

        userStakedBTC[msg.sender] = userStakedBTC[msg.sender].sub(btcAmount);
        userMintedLstBTC[msg.sender] = userMintedLstBTC[msg.sender].sub(lstBTCAmount);

        emit BTCUnstaked(msg.sender, lstBTCAmount, btcAmount);
        return btcAmount;
    }

    /**
     * @dev Returns the accumulated staking rewards for a user.
     */
    function getStakingRewards(address user) external view returns (uint256) {
        return userStakingRewards[user];
    }

    /**
     * @dev Claims accumulated staking rewards for a user.
     * In a real system, it might mint new lstBTC or another reward token.
     */
    function claimRewards(address user) external nonReentrant returns (uint256) {
        uint256 rewards = userStakingRewards[user];
        require(rewards > 0, "No rewards to claim");

        userStakingRewards[user] = 0;
        lstBTC.mint(user, rewards);

        emit RewardsClaimed(user, rewards);
        return rewards;
    }

    /**
     * @dev Returns the lstBTC balance associated with a user's stake.
     */
    function getLstBTCBalance(address user) external view returns (uint256) {
        return userMintedLstBTC[user];
    }

    /**
     * @dev Owner can add rewards for a user for testing purposes.
     */
    function addRewards(address user, uint256 amount) external onlyOwner {
        userStakingRewards[user] = userStakingRewards[user].add(amount);
    }
}
