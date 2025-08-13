// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../interfaces/IBTCStaking.sol";
import "../interfaces/ILstBTC.sol";
import {TestPriceFeed} from "../feeds/TestPriceFeed.sol";

// PRICE FEED 0x48686EA995462d611F4DA0d65f90B21a30F259A5
// lstBTC 0xDeA521E585D429291f99631D751f5f02F544909b  
//MOCK BTC 0xF12D5E4D561000F1F464E4576bb27eA0e83931da
// BTCSTAKING 0xBc6d8B5cC83E32079f75bB44cF723699B34c8495
/**
[
  "0x6765e788d5652E22691C6c3385c401a9294B9375",
  "0x25a8e2d1e9883D1909040b6B3eF2bb91feAB2e2f",
  "0xC7d68ce9A8047D4bF64E6f7B79d388a11944A06E",
  "0x2B2068a831e7C7B2Ac4D97Cd293F934d2625aB69",
  "0x48D2210bd4E72c741F74E6c0E8f356b2C36ebB7A",
  "0x7dd1aD415F58D91BbF76BcC2640cc6FdD44Aa94b",
  "0x8F11F588B1Cc0Bc88687F7d07d5A529d34e5CD84",
  "0xaC56E37f70407f279e27cFcf2E31EdCa888EaEe4"
]

*/


/**
* @title LendingPool - ENHANCED VERSION
* @dev Core lending and borrowing logic with dual collateral system using lstBTC
* Features production-ready interest accrual and borrowing calculations
*/
contract LendingPool is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    // State variables
    IBTCStaking public btcStaking;
    ILstBTC public lstBTC;
    TestPriceFeed public priceOracle;
    address public btcToken;

    // Supported tokens for borrowing
    mapping(address => bool) public supportedTokens;
    mapping(address => uint256) public tokenReserves;
    mapping(address => uint256) public totalTokenBorrows;
    
    // NEW: Track which tokens each user has borrowed
    mapping(address => address[]) public userBorrowedTokens;
    mapping(address => mapping(address => bool)) public userHasBorrowed;
    
    // NEW: Global and per-token interest rate indices for compound interest
    mapping(address => uint256) public tokenBorrowIndex; // Cumulative borrow index per token
    mapping(address => uint256) public tokenLastUpdateTime; // Last update time per token
    mapping(address => mapping(address => uint256)) public userTokenBorrowIndex; // User's borrow index when they last interacted

    // Enhanced User positions
    struct UserPosition {
        uint256 btcCollateral;
        uint256 lstBTCCollateral;
        uint256 lastUpdateTime;
        mapping(address => uint256) tokenBorrows; // Principal amount borrowed per token
        mapping(address => uint256) accruedInterest; // Accrued interest per token
        uint256 healthFactor;
        uint256 stakingRewards;
    }

    mapping(address => UserPosition) public userPositions;

    // Protocol parameters
    uint256 public constant BTC_COLLATERAL_RATIO = 150;
    uint256 public constant LSTBTC_COLLATERAL_RATIO = 120;
    uint256 public constant LIQUIDATION_THRESHOLD = 110;
    uint256 public constant LIQUIDATION_PENALTY = 10;
    uint256 public constant PROTOCOL_FEE = 10;

    // Interest rate model parameters
    uint256 public baseInterestRate = 5e16; // 5% base rate
    uint256 public utilizationMultiplier = 10e16; // 10% utilization multiplier
    uint256 public maxInterestRate = 50e16; // 50% max rate
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // Events (keeping existing ones and adding new)
    event InterestAccrued(address indexed user, address indexed token, uint256 interest);
    event GlobalIndexUpdated(address indexed token, uint256 newIndex, uint256 interestRate);
    
    // ... (keeping all existing events)
    event Deposit(address indexed user, uint256 btcAmount, uint256 lstBTCMinted);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidation(address indexed user, address indexed liquidator, uint256 collateralSeized);
    event Withdraw(address indexed user, uint256 btcAmount, uint256 lstBTCBurned);
    event RewardsClaimed(address indexed user, uint256 amount);
    event TokenAdded(address indexed token, uint256 initialReserve);
    event TokenRemoved(address indexed token);
    event LiquidityAdded(address indexed token, uint256 amount, uint256 totalReserves);
    event LiquidityRemoved(address indexed token, uint256 amount, uint256 totalReserves);

    constructor(
        address _btcStaking,
        address _lstBTC,
        address _priceOracle,
        address _btcToken,
        address[] memory _initialSupportedTokens
    ) Ownable(msg.sender) {
        require(_btcStaking != address(0), "Invalid BTC staking address");
        require(_lstBTC != address(0), "Invalid lstBTC address");
        require(_priceOracle != address(0), "Invalid oracle address");
        require(_btcToken != address(0), "Invalid BTC token address");
        
        btcStaking = IBTCStaking(_btcStaking);
        lstBTC = ILstBTC(_lstBTC);
        priceOracle = TestPriceFeed(_priceOracle);
        btcToken = _btcToken;
        _setInitialSupportedTokens(_initialSupportedTokens);
        
        // Initialize borrow indices
        _initializeBorrowIndices(_initialSupportedTokens);
    }

    // =============================================================================
    // PRODUCTION-READY CORE FUNCTIONS
    // =============================================================================

    /**
     * @dev PRODUCTION-READY: Calculate total borrowed amount in USD for a user
     * @param user Address of the user
     * @return totalBorrowedUSD Total borrowed amount in USD (including accrued interest)
     */
    function _calculateTotalBorrowedUSD(address user) internal view returns (uint256 totalBorrowedUSD) {
        address[] memory borrowedTokens = userBorrowedTokens[user];
        
        for (uint256 i = 0; i < borrowedTokens.length; i++) {
            address token = borrowedTokens[i];
            
            // Get current total debt including accrued interest
            uint256 currentDebt = _calculateCurrentDebt(user, token);
            
            if (currentDebt > 0) {
                uint256 tokenPrice = priceOracle.getLatestPrice(token);
                uint256 debtValueUSD = currentDebt.mul(tokenPrice).div(1e18);
                totalBorrowedUSD = totalBorrowedUSD.add(debtValueUSD);
            }
        }
        
        return totalBorrowedUSD;
    }

    /**
     * @dev PRODUCTION-READY: Calculate current debt for a specific token including accrued interest
     * @param user Address of the user
     * @param token Address of the token
     * @return currentDebt Total debt including principal and accrued interest
     */
    function _calculateCurrentDebt(address user, address token) internal view returns (uint256 currentDebt) {
        UserPosition storage position = userPositions[user];
        uint256 principal = position.tokenBorrows[token];
        
        if (principal == 0) {
            return 0;
        }

        // Calculate accrued interest using compound interest formula
        uint256 currentBorrowIndex = _getCurrentBorrowIndex(token);
        uint256 userBorrowIndex = userTokenBorrowIndex[user][token];
        
        if (userBorrowIndex == 0) {
            // User hasn't borrowed this token yet
            return principal;
        }

        // Current debt = principal * (current_index / user_index)
        currentDebt = principal.mul(currentBorrowIndex).div(userBorrowIndex);
        
        return currentDebt;
    }

    /**
     * @dev PRODUCTION-READY: Accrue interest for a user's position across all borrowed tokens
     * @param user Address of the user
     */
    function _accrueInterest(address user) internal {
        address[] memory borrowedTokens = userBorrowedTokens[user];
        
        // First update global indices for all relevant tokens
        for (uint256 i = 0; i < borrowedTokens.length; i++) {
            address token = borrowedTokens[i];
            _updateTokenBorrowIndex(token);
        }
        
        // Then accrue interest for user positions
        UserPosition storage position = userPositions[user];
        
        for (uint256 i = 0; i < borrowedTokens.length; i++) {
            address token = borrowedTokens[i];
            uint256 principal = position.tokenBorrows[token];
            
            if (principal > 0) {
                uint256 newTotalDebt = _calculateCurrentDebt(user, token);
                uint256 accruedInterest = newTotalDebt.sub(principal);
                
                // Update user's accrued interest
                position.accruedInterest[token] = position.accruedInterest[token].add(accruedInterest);
                
                // Update user's borrow index to current
                userTokenBorrowIndex[user][token] = tokenBorrowIndex[token];
                
                if (accruedInterest > 0) {
                    emit InterestAccrued(user, token, accruedInterest);
                }
            }
        }
        
        position.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Update the global borrow index for a specific token
     * @param token Address of the token
     */
    function _updateTokenBorrowIndex(address token) internal {
        uint256 timeElapsed = block.timestamp.sub(tokenLastUpdateTime[token]);
        
        if (timeElapsed == 0) {
            return; // No time has passed
        }
        
        uint256 borrowRate = _calculateBorrowRate(token);
        uint256 interestFactor = borrowRate.mul(timeElapsed).div(SECONDS_PER_YEAR);
        
        // Compound interest: newIndex = oldIndex * (1 + rate * time)
        uint256 currentIndex = tokenBorrowIndex[token];
        uint256 newIndex = currentIndex.mul(uint256(1e18).add(interestFactor)).div(1e18);
        
        tokenBorrowIndex[token] = newIndex;
        tokenLastUpdateTime[token] = block.timestamp;
        
        emit GlobalIndexUpdated(token, newIndex, borrowRate);
    }

    /**
     * @dev Get current borrow index for a token (without updating state)
     * @param token Address of the token
     * @return Current borrow index
     */
    function _getCurrentBorrowIndex(address token) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp.sub(tokenLastUpdateTime[token]);
        
        if (timeElapsed == 0) {
            return tokenBorrowIndex[token];
        }
        
        uint256 borrowRate = _calculateBorrowRate(token);
        uint256 interestFactor = borrowRate.mul(timeElapsed).div(SECONDS_PER_YEAR);
        
        uint256 currentIndex = tokenBorrowIndex[token];
        return currentIndex.mul(uint256(1e18).add(interestFactor)).div(1e18);
    }

    /**
     * @dev Calculate borrow rate for a specific token based on utilization
     * @param token Address of the token
     * @return Borrow rate per second (scaled by 1e18)
     */
    function _calculateBorrowRate(address token) internal view returns (uint256) {
        uint256 totalSupply = tokenReserves[token].add(totalTokenBorrows[token]);
        
        if (totalSupply == 0) {
            return baseInterestRate;
        }
        
        uint256 utilization = totalTokenBorrows[token].mul(1e18).div(totalSupply);
        uint256 utilizationRate = utilization.mul(utilizationMultiplier).div(1e18);
        uint256 borrowRate = baseInterestRate.add(utilizationRate);
        
        // Cap at maximum rate
        if (borrowRate > maxInterestRate) {
            borrowRate = maxInterestRate;
        }
        
        return borrowRate;
    }

    // =============================================================================
    // ENHANCED CORE LENDING FUNCTIONS
    // =============================================================================

    /**
     * @dev Enhanced borrow function with proper interest tracking
     */
    function borrow(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount must be greater than 0");
        require(tokenReserves[token] >= amount, "Insufficient liquidity");

        // Update global index and accrue interest first
        _updateTokenBorrowIndex(token);
        _accrueInterest(msg.sender);

        UserPosition storage position = userPositions[msg.sender];

        // Check collateral sufficiency
        uint256 maxBorrowable = _calculateMaxBorrowable(msg.sender);
        uint256 tokenPrice = priceOracle.getLatestPrice(token);
        uint256 borrowValueUSD = amount.mul(tokenPrice).div(1e18);
        uint256 currentTotalBorrowedUSD = _calculateTotalBorrowedUSD(msg.sender);
        
        require(currentTotalBorrowedUSD.add(borrowValueUSD) <= maxBorrowable, "Insufficient collateral");

        // Track this token if user hasn't borrowed it before
        if (!userHasBorrowed[msg.sender][token]) {
            userBorrowedTokens[msg.sender].push(token);
            userHasBorrowed[msg.sender][token] = true;
            // Set initial borrow index for this user-token pair
            userTokenBorrowIndex[msg.sender][token] = tokenBorrowIndex[token];
        }

        // Update user position
        position.tokenBorrows[token] = position.tokenBorrows[token].add(amount);
        position.lastUpdateTime = block.timestamp;

        // Update global tracking
        tokenReserves[token] = tokenReserves[token].sub(amount);
        totalTokenBorrows[token] = totalTokenBorrows[token].add(amount);

        // Transfer tokens to user
        require(IERC20(token).transfer(msg.sender, amount), "Token transfer failed");

        // Update health factor
        _updateHealthFactor(msg.sender);

        emit Borrow(msg.sender, token, amount);
    }

    /**
     * @dev Enhanced repay function with proper interest handling
     */
    function repay(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount must be greater than 0");

        // Update interest first
        _updateTokenBorrowIndex(token);
        _accrueInterest(msg.sender);

        UserPosition storage position = userPositions[msg.sender];
        uint256 currentDebt = _calculateCurrentDebt(msg.sender, token);
        
        require(currentDebt >= amount, "Repay amount exceeds debt");

        // Transfer tokens from user
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        // Calculate how much goes to principal vs interest
        uint256 accruedInterest = position.accruedInterest[token];
        uint256 principal = position.tokenBorrows[token];
        
        if (amount >= accruedInterest) {
            // Pay off all interest first, then principal
            uint256 principalPayment = amount.sub(accruedInterest);
            position.accruedInterest[token] = 0;
            position.tokenBorrows[token] = principal.sub(principalPayment);
            
            // Update global principal tracking
            totalTokenBorrows[token] = totalTokenBorrows[token].sub(principalPayment);
        } else {
            // Only paying interest
            position.accruedInterest[token] = accruedInterest.sub(amount);
        }

        // If debt is fully paid, remove token from user's borrowed tokens list
        if (_calculateCurrentDebt(msg.sender, token) == 0) {
            _removeTokenFromUserBorrowedList(msg.sender, token);
        }

        position.lastUpdateTime = block.timestamp;
        tokenReserves[token] = tokenReserves[token].add(amount);

        // Update health factor
        _updateHealthFactor(msg.sender);

        emit Repay(msg.sender, token, amount);
    }

    // =============================================================================
    // HELPER FUNCTIONS
    // =============================================================================

    /**
     * @dev Remove a token from user's borrowed tokens list
     */
    function _removeTokenFromUserBorrowedList(address user, address token) internal {
        address[] storage borrowedTokens = userBorrowedTokens[user];
        
        for (uint256 i = 0; i < borrowedTokens.length; i++) {
            if (borrowedTokens[i] == token) {
                // Move last element to current position and pop
                borrowedTokens[i] = borrowedTokens[borrowedTokens.length - 1];
                borrowedTokens.pop();
                userHasBorrowed[user][token] = false;
                break;
            }
        }
    }

    /**
     * @dev Initialize borrow indices for supported tokens
     */
    function _initializeBorrowIndices(address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenBorrowIndex[tokens[i]] = 1e18; // Start with 1.0 index
            tokenLastUpdateTime[tokens[i]] = block.timestamp;
        }
    }

    // =============================================================================
    // VIEW FUNCTIONS - ENHANCED
    // =============================================================================

    /**
     * @dev Get user's current debt for a specific token including interest
     */
    function getUserCurrentDebt(address user, address token) external view returns (uint256) {
        return _calculateCurrentDebt(user, token);
    }

    /**
     * @dev Get user's total borrowed amount in USD including accrued interest
     */
    function getUserTotalBorrowedUSD(address user) external view returns (uint256) {
        return _calculateTotalBorrowedUSD(user);
    }

    /**
     * @dev Get list of tokens a user has borrowed
     */
    function getUserBorrowedTokens(address user) external view returns (address[] memory) {
        return userBorrowedTokens[user];
    }

    /**
     * @dev Get current borrow rate for a token
     */
    function getCurrentBorrowRate(address token) external view returns (uint256) {
        return _calculateBorrowRate(token);
    }

    /**
     * @dev Get current borrow index for a token
     */
    function getCurrentBorrowIndex(address token) external view returns (uint256) {
        return _getCurrentBorrowIndex(token);
    }

    // =============================================================================
    // EXISTING FUNCTIONS (keeping the rest of your contract unchanged)
    // =============================================================================

    function depositBTC(uint256 btcAmount) external nonReentrant whenNotPaused {
        require(btcAmount > 0, "Amount must be greater than 0");

        require(IERC20(btcToken).transferFrom(msg.sender, address(this), btcAmount), "BTC transfer failed");
        require(IERC20(btcToken).approve(address(btcStaking), btcAmount), "BTC approval failed");

        uint256 lstBTCAmount = btcStaking.stake(btcAmount);

        UserPosition storage position = userPositions[msg.sender];
        position.btcCollateral = position.btcCollateral.add(btcAmount);
        position.lstBTCCollateral = position.lstBTCCollateral.add(lstBTCAmount);
        position.lastUpdateTime = block.timestamp;

        lstBTC.mint(msg.sender, lstBTCAmount);
        _updateHealthFactor(msg.sender);

        emit Deposit(msg.sender, btcAmount, lstBTCAmount);
    }

    /**
 * @dev Function to allow users to withdraw their BTC collateral
 * @param btcAmount Amount of BTC to withdraw
 */
function withdrawBTC(uint256 btcAmount) external nonReentrant whenNotPaused {
    require(btcAmount > 0, "Amount must be greater than 0");

    UserPosition storage position = userPositions[msg.sender];
    require(position.btcCollateral >= btcAmount, "Insufficient BTC collateral");

    // Calculate the corresponding lstBTC amount to burn
    uint256 lstBTCAmount = btcStaking.unstake(btcAmount);

    // Update user's collateral and lstBTC balances
    position.btcCollateral = position.btcCollateral.sub(btcAmount);
    position.lstBTCCollateral = position.lstBTCCollateral.sub(lstBTCAmount);

    // Burn the corresponding lstBTC tokens
    lstBTC.burn(msg.sender, lstBTCAmount);

    // Transfer BTC back to the user
    require(IERC20(btcToken).transfer(msg.sender, btcAmount), "BTC transfer failed");

    // Update health factor
    _updateHealthFactor(msg.sender);

    emit Withdraw(msg.sender, btcAmount, lstBTCAmount);
}

    function _calculateMaxBorrowable(address user) internal view returns (uint256) {
        UserPosition storage position = userPositions[user];

        uint256 btcPrice = priceOracle.getLatestPrice(btcToken);
        uint256 lstBTCPrice = priceOracle.getLatestPrice(address(lstBTC));

        uint256 btcCollateralValue = position.btcCollateral.mul(btcPrice).div(1e18);
        uint256 lstBTCCollateralValue = position.lstBTCCollateral.mul(lstBTCPrice).div(1e18);

        uint256 maxBorrowFromBTC = btcCollateralValue.mul(100).div(BTC_COLLATERAL_RATIO);
        uint256 maxBorrowFromLstBTC = lstBTCCollateralValue.mul(100).div(LSTBTC_COLLATERAL_RATIO);

        return maxBorrowFromBTC.add(maxBorrowFromLstBTC);
    }

    function _calculateCollateralValue(uint256 btcAmount, uint256 lstBTCAmount) internal view returns (uint256) {
        uint256 btcPrice = priceOracle.getLatestPrice(btcToken);
        uint256 lstBTCPrice = priceOracle.getLatestPrice(address(lstBTC));

        uint256 btcValue = btcAmount.mul(btcPrice).div(1e18);
        uint256 lstBTCValue = lstBTCAmount.mul(lstBTCPrice).div(1e18);

        return btcValue.add(lstBTCValue);
    }

    function _updateHealthFactor(address user) internal {
        UserPosition storage position = userPositions[user];

        uint256 totalBorrowedUSD = _calculateTotalBorrowedUSD(user);
        
        if (totalBorrowedUSD == 0) {
            position.healthFactor = type(uint256).max;
            return;
        }

        uint256 totalCollateralValue = _calculateCollateralValue(position.btcCollateral, position.lstBTCCollateral);
        position.healthFactor = totalCollateralValue.mul(100).div(totalBorrowedUSD);
    }

    // Add the missing functions that would be needed...
    function _setInitialSupportedTokens(address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            require(token != address(0), "Invalid token address");
            require(token != btcToken, "Cannot add BTC as supported token");
            require(token != address(lstBTC), "Cannot add lstBTC as supported token");
            require(!supportedTokens[token], "Token already supported");

            supportedTokens[token] = true;
            tokenReserves[token] = 0;
            totalTokenBorrows[token] = 0;

            emit TokenAdded(token, 0);
        }
    }

    // Additional view function to maintain compatibility
    function getUserPosition(address user) external view returns (
        uint256 btcCollateral,
        uint256 lstBTCCollateral,
        uint256 totalBorrowed,
        uint256 healthFactor,
        uint256 stakingRewards
    ) {
        UserPosition storage position = userPositions[user];
        uint256 totalBorrowedUSD = _calculateTotalBorrowedUSD(user);
        
        return (
            position.btcCollateral,
            position.lstBTCCollateral,
            totalBorrowedUSD,
            position.healthFactor,
            position.stakingRewards
        );
    }

    function getUserBorrowedAmount(address user, address token) external view returns (uint256) {
        return userPositions[user].tokenBorrows[token];
    }

    /**
 * @dev Function to add liquidity to the pool
 * @param token Address of the token to add liquidity for
 * @param amount Amount of tokens to add
 */
function addLiquidity(address token, uint256 amount) external onlyOwner nonReentrant whenNotPaused {
    require(supportedTokens[token], "Token not supported");
    require(amount > 0, "Amount must be greater than 0");

    // Transfer tokens from owner to this contract
    require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Token transfer failed");

    // Update token reserves
    tokenReserves[token] = tokenReserves[token].add(amount);

    // Emit event
    emit LiquidityAdded(token, amount, tokenReserves[token]);
}
}