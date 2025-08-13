// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../interfaces/IBTCStaking.sol";
import "../interfaces/ILstBTC.sol"; 
import "../interfaces/ICustodian.sol";

import {TestPriceFeed} from "../feeds/TestPriceFeed.sol";



/**
 * @title YieldVault - Enhanced Yield Generation for wBTC and LSTs
 * @dev A sophisticated yield vault that converts wBTC and LSTs to lstBTC for enhanced yield generation
 * Features custodian-based conversions, yield optimization, and flexible withdrawal options
 */
contract YieldVault is ERC20, ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    // Core protocol contracts
    IBTCStaking public btcStaking;
    ILstBTC public lstBTC;
    ICustodian public custodian;
    TestPriceFeed public priceOracle;
    
    // Supported tokens
    address public wbtcToken;
    mapping(address => bool) public supportedLSTs;
    address[] public supportedLSTList;
    
    // Vault parameters
    uint256 public constant PERFORMANCE_FEE = 1000; // 10% performance fee (basis points)
    uint256 public constant MANAGEMENT_FEE = 200;   // 2% annual management fee
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    // Fee collection
    address public treasury;
    uint256 public totalPerformanceFees;
    uint256 public totalManagementFees;
    uint256 public lastManagementFeeCollection;
    
    // Vault metrics
    uint256 public totalLstBTCManaged;
    uint256 public totalYieldGenerated;
    uint256 public totalDepositors;
    
    // User tracking
    struct UserInfo {
        uint256 depositedWBTC;
        uint256 depositedLSTValue; // USD value of LSTs deposited
        mapping(address => uint256) lstDeposits; // Amount of each LST deposited
        uint256 lstBTCBalance;
        uint256 yieldEarned;
        uint256 lastYieldUpdate;
        uint256 depositTimestamp;
        bool hasDeposited;
    }
    
    mapping(address => UserInfo) public userInfo;
    address[] public depositors;
    
    // Yield distribution tracking
    uint256 public accumulatedYieldPerShare;
    uint256 public lastYieldDistribution;
    mapping(address => uint256) public userYieldDebt;
    
    // Rebalancing parameters
    uint256 public rebalanceThreshold = 5e16; // 5% threshold
    uint256 public maxSlippage = 100; // 1% max slippage
    bool public autoRebalanceEnabled = true;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event WBTCDeposited(address indexed user, uint256 wbtcAmount, uint256 lstBTCReceived, uint256 sharesIssued);
    event LSTDeposited(address indexed user, address indexed lstToken, uint256 lstAmount, uint256 lstBTCReceived, uint256 sharesIssued);
    event WithdrawalRequested(address indexed user, uint256 sharesAmount, uint256 lstBTCAmount);
    event WithdrawalExecuted(address indexed user, address indexed outputToken, uint256 outputAmount);
    event YieldDistributed(uint256 totalYield, uint256 yieldPerShare, uint256 timestamp);
    event YieldClaimed(address indexed user, uint256 yieldAmount);
    event PerformanceFeeCollected(uint256 feeAmount);
    event ManagementFeeCollected(uint256 feeAmount);
    event Rebalanced(uint256 lstBTCAmount, uint256 newTotalManaged);
    event CustodianUpdated(address indexed oldCustodian, address indexed newCustodian);
    event LSTAdded(address indexed lstToken);
    event LSTRemoved(address indexed lstToken);
    event EmergencyWithdrawal(address indexed user, uint256 amount);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _btcStaking,
        address _lstBTC,
        address _custodian,
        address _priceOracle,
        address _wbtcToken,
        address _treasury,
        address[] memory _initialLSTs
    ) ERC20("lstBTC Yield Vault Token", "yLSTBTC") Ownable(msg.sender) {
        require(_btcStaking != address(0), "Invalid BTC staking address");
        require(_lstBTC != address(0), "Invalid lstBTC address");
        require(_custodian != address(0), "Invalid custodian address");
        require(_priceOracle != address(0), "Invalid oracle address");
        require(_wbtcToken != address(0), "Invalid wBTC address");
        require(_treasury != address(0), "Invalid treasury address");
        
        btcStaking = IBTCStaking(_btcStaking);
        lstBTC = ILstBTC(_lstBTC);
        custodian = ICustodian(_custodian);
        priceOracle = TestPriceFeed(_priceOracle);
        wbtcToken = _wbtcToken;
        treasury = _treasury;
        
        lastManagementFeeCollection = block.timestamp;
        lastYieldDistribution = block.timestamp;
        
        _addInitialLSTs(_initialLSTs);
    }
    
    // =============================================================================
    // CORE DEPOSIT FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Deposit wBTC into the vault and convert to lstBTC for yield generation
     * @param wbtcAmount Amount of wBTC to deposit
     * @return sharesIssued Amount of vault shares issued to the user
     */
    function depositWBTC(uint256 wbtcAmount) external nonReentrant whenNotPaused returns (uint256 sharesIssued) {
        require(wbtcAmount > 0, "Amount must be greater than 0");
        
        // Transfer wBTC from user
        require(IERC20(wbtcToken).transferFrom(msg.sender, address(this), wbtcAmount), "wBTC transfer failed");
        
        // Approve custodian to spend wBTC
        require(IERC20(wbtcToken).approve(address(custodian), wbtcAmount), "wBTC approval failed");
        
        // Convert wBTC to lstBTC through custodian
        uint256 lstBTCReceived = custodian.convertWBTCToLstBTC(wbtcAmount);
        require(lstBTCReceived > 0, "Conversion failed");
        
        // Update user info
        UserInfo storage user = userInfo[msg.sender];
        if (!user.hasDeposited) {
            depositors.push(msg.sender);
            totalDepositors = totalDepositors.add(1);
            user.hasDeposited = true;
            user.depositTimestamp = block.timestamp;
        }
        
        user.depositedWBTC = user.depositedWBTC.add(wbtcAmount);
        user.lstBTCBalance = user.lstBTCBalance.add(lstBTCReceived);
        user.lastYieldUpdate = block.timestamp;
        
        // Calculate shares to issue (based on current vault value)
        sharesIssued = _calculateSharesToIssue(lstBTCReceived);
        
        // Update vault metrics
        totalLstBTCManaged = totalLstBTCManaged.add(lstBTCReceived);
        
        // Mint shares to user
        _mint(msg.sender, sharesIssued);
        
        // Update yield debt for fair distribution
        userYieldDebt[msg.sender] = userYieldDebt[msg.sender].add(sharesIssued.mul(accumulatedYieldPerShare).div(1e18));
        
        emit WBTCDeposited(msg.sender, wbtcAmount, lstBTCReceived, sharesIssued);
        
        // Auto-rebalance if enabled and threshold met
        _checkAndRebalance();
        
        return sharesIssued;
    }
    
    /**
     * @dev Deposit LST into the vault and convert to lstBTC for yield generation
     * @param lstToken Address of the LST token to deposit
     * @param lstAmount Amount of LST to deposit
     * @return sharesIssued Amount of vault shares issued to the user
     */
    function depositLST(address lstToken, uint256 lstAmount) external nonReentrant whenNotPaused returns (uint256 sharesIssued) {
        require(lstAmount > 0, "Amount must be greater than 0");
        require(supportedLSTs[lstToken], "LST not supported");
        
        // Transfer LST from user
        require(IERC20(lstToken).transferFrom(msg.sender, address(this), lstAmount), "LST transfer failed");
        
        // Approve custodian to spend LST
        require(IERC20(lstToken).approve(address(custodian), lstAmount), "LST approval failed");
        
        // Convert LST to lstBTC through custodian
        uint256 lstBTCReceived = custodian.convertLSTToLstBTC(lstToken, lstAmount);
        require(lstBTCReceived > 0, "Conversion failed");
        
        
        // Update user info
        UserInfo storage user = userInfo[msg.sender];
        if (!user.hasDeposited) {
            depositors.push(msg.sender);
            totalDepositors = totalDepositors.add(1);
            user.hasDeposited = true;
            user.depositTimestamp = block.timestamp;
        }
        
        // Calculate USD value of LST deposited
        uint256 lstPrice = priceOracle.getLatestPrice(lstToken);
        uint256 lstValueUSD = lstAmount.mul(lstPrice).div(1e18);
        
        user.lstDeposits[lstToken] = user.lstDeposits[lstToken].add(lstAmount);
        user.depositedLSTValue = user.depositedLSTValue.add(lstValueUSD);
        user.lstBTCBalance = user.lstBTCBalance.add(lstBTCReceived);
        user.lastYieldUpdate = block.timestamp;
        
        // Calculate shares to issue
        sharesIssued = _calculateSharesToIssue(lstBTCReceived);
        
        // Update vault metrics
        totalLstBTCManaged = totalLstBTCManaged.add(lstBTCReceived);
        
        // Mint shares to user
        _mint(msg.sender, sharesIssued);
        
        // Update yield debt
        userYieldDebt[msg.sender] = userYieldDebt[msg.sender].add(sharesIssued.mul(accumulatedYieldPerShare).div(1e18));
        
        emit LSTDeposited(msg.sender, lstToken, lstAmount, lstBTCReceived, sharesIssued);
        
        // Auto-rebalance if enabled
        _checkAndRebalance();
        
        return sharesIssued;
        
    }
    
    // =============================================================================
    // WITHDRAWAL FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Request withdrawal of vault shares
     * @param sharesAmount Amount of vault shares to withdraw
     * @param outputToken Address of desired output token (wBTC or supported LST)
     */
 function requestWithdrawal(uint256 sharesAmount, address outputToken) external nonReentrant whenNotPaused {
    require(sharesAmount > 0, "Shares amount must be greater than 0");
    require(balanceOf(msg.sender) >= sharesAmount, "Insufficient shares");
    require(outputToken == wbtcToken || supportedLSTs[outputToken], "Output token not supported");
    
    // Update yields before withdrawal
    _updateUserYield(msg.sender);
    
    // Calculate lstBTC amount corresponding to shares
    uint256 lstBTCAmount = sharesAmount.mul(totalLstBTCManaged).div(totalSupply());
    
    // Burn user shares
    _burn(msg.sender, sharesAmount);
    
    // Update user lstBTC balance
    UserInfo storage user = userInfo[msg.sender];
    user.lstBTCBalance = user.lstBTCBalance.sub(lstBTCAmount);
    
    // Calculate proportional withdrawal from original deposits
    uint256 totalUserShares = balanceOf(msg.sender).add(sharesAmount); // Total before burning
    uint256 withdrawalRatio = sharesAmount.mul(1e18).div(totalUserShares);
    
    // Proportionally reduce the original deposit tracking
    if (outputToken == wbtcToken) {
        // Reduce depositedWBTC proportionally to the shares being withdrawn
        uint256 wbtcToReduce = user.depositedWBTC.mul(withdrawalRatio).div(1e18);
        user.depositedWBTC = user.depositedWBTC.sub(wbtcToReduce);
    } else {
        // Reduce depositedLSTValue proportionally to the shares being withdrawn
        uint256 lstValueToReduce = user.depositedLSTValue.mul(withdrawalRatio).div(1e18);
        user.depositedLSTValue = user.depositedLSTValue.sub(lstValueToReduce);
        
        // Also reduce the specific LST deposit tracking
        uint256 specificLSTToReduce = user.lstDeposits[outputToken].mul(withdrawalRatio).div(1e18);
        user.lstDeposits[outputToken] = user.lstDeposits[outputToken].sub(specificLSTToReduce);
    }
    
    emit WithdrawalRequested(msg.sender, sharesAmount, lstBTCAmount);
    
    // Execute conversion and transfer
    _executeWithdrawal(msg.sender, lstBTCAmount, outputToken);
}
    
    /**
     * @dev Execute withdrawal conversion and transfer
     * @param user Address of the user
     * @param lstBTCAmount Amount of lstBTC to convert
     * @param outputToken Desired output token
     */
function _executeWithdrawal(address user, uint256 lstBTCAmount, address outputToken) internal {
    uint256 outputAmount;
    
    // Approve custodian to spend lstBTC
    require(lstBTC.approve(address(custodian), lstBTCAmount), "lstBTC approval failed");
    
    if (outputToken == wbtcToken) {
        // Convert lstBTC to wBTC
        outputAmount = custodian.convertLstBTCToWBTC(lstBTCAmount);
        require(IERC20(wbtcToken).transfer(user, outputAmount), "wBTC transfer failed");
    } else {
        // Convert lstBTC to specified LST
        outputAmount = custodian.convertLstBTCToLST(lstBTCAmount, outputToken);
        require(IERC20(outputToken).transfer(user, outputAmount), "LST transfer failed");
    }
    
    // Update vault metrics
    totalLstBTCManaged = totalLstBTCManaged.sub(lstBTCAmount);
    
    // NO MORE DUPLICATE SUBTRACTION HERE - it's already handled in requestWithdrawal
    
    emit WithdrawalExecuted(user, outputToken, outputAmount);
}
    
    // =============================================================================
    // YIELD MANAGEMENT FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Distribute yield to all vault participants
     */
   function distributeYield() external nonReentrant {
    require(block.timestamp >= lastYieldDistribution.add(1 days), "Too early for yield distribution");
    
    // Get current lstBTC balance (includes staking rewards)
    uint256 currentBalance = lstBTC.balanceOf(address(this));
    
    if (currentBalance > totalLstBTCManaged) {
        uint256 yieldGenerated = currentBalance.sub(totalLstBTCManaged);
        
        // Collect performance fee
        uint256 performanceFee = yieldGenerated.mul(PERFORMANCE_FEE).div(BASIS_POINTS);
        uint256 netYield = yieldGenerated.sub(performanceFee);
        
        // Update accumulated yield per share
        uint256 yieldPerShare = 0; // Initialize yieldPerShare here
        if (totalSupply() > 0) {
            yieldPerShare = netYield.mul(1e18).div(totalSupply());
            accumulatedYieldPerShare = accumulatedYieldPerShare.add(yieldPerShare);
        }
        
        // Update metrics
        totalYieldGenerated = totalYieldGenerated.add(netYield);
        totalPerformanceFees = totalPerformanceFees.add(performanceFee);
        totalLstBTCManaged = currentBalance.sub(performanceFee);
        lastYieldDistribution = block.timestamp;
        
        // Transfer performance fee to treasury
        if (performanceFee > 0) {
            require(lstBTC.transfer(treasury, performanceFee), "Fee transfer failed");
            emit PerformanceFeeCollected(performanceFee);
        }
        
        emit YieldDistributed(netYield, yieldPerShare, block.timestamp);
    }
    
    // Collect management fee
    _collectManagementFee();
}
    
    /**
     * @dev Claim accumulated yield for a user
     */
    function claimYield() external nonReentrant {
        _updateUserYield(msg.sender);
        
        UserInfo storage user = userInfo[msg.sender];
        uint256 claimableYield = user.yieldEarned;
        
        require(claimableYield > 0, "No yield to claim");
        
        // Reset user yield
        user.yieldEarned = 0;
        user.lastYieldUpdate = block.timestamp;
        
        // Transfer yield to user
        require(lstBTC.transfer(msg.sender, claimableYield), "Yield transfer failed");
        
        emit YieldClaimed(msg.sender, claimableYield);
    }
    
    /**
     * @dev Update yield for a specific user
     * @param user Address of the user
     */
    function _updateUserYield(address user) internal {
        UserInfo storage userInfo_ = userInfo[user];
        uint256 userShares = balanceOf(user);
        
        if (userShares > 0) {
            uint256 pendingYield = userShares.mul(accumulatedYieldPerShare).div(1e18).sub(userYieldDebt[user]);
            userInfo_.yieldEarned = userInfo_.yieldEarned.add(pendingYield);
        }
        
        userYieldDebt[user] = userShares.mul(accumulatedYieldPerShare).div(1e18);
        userInfo_.lastYieldUpdate = block.timestamp;
    }
    
    /**
     * @dev Collect management fee from the vault
     */
    function _collectManagementFee() internal {
        uint256 timeElapsed = block.timestamp.sub(lastManagementFeeCollection);
        
        if (timeElapsed >= 30 days && totalLstBTCManaged > 0) {
            uint256 annualFee = totalLstBTCManaged.mul(MANAGEMENT_FEE).div(BASIS_POINTS);
            uint256 managementFee = annualFee.mul(timeElapsed).div(SECONDS_PER_YEAR);
            
            if (managementFee > 0 && lstBTC.balanceOf(address(this)) >= managementFee) {
                totalManagementFees = totalManagementFees.add(managementFee);
                lastManagementFeeCollection = block.timestamp;
                
                require(lstBTC.transfer(treasury, managementFee), "Management fee transfer failed");
                emit ManagementFeeCollected(managementFee);
            }
        }
    }
    
    // =============================================================================
    // REBALANCING FUNCTIONS
    // =============================================================================


    
    /**
     * @dev Check if rebalancing is needed and execute if threshold is met
     */
    function _checkAndRebalance() internal {
        if (!autoRebalanceEnabled) return;
        
        uint256 currentBalance = lstBTC.balanceOf(address(this));
        uint256 deviation = currentBalance > totalLstBTCManaged 
            ? currentBalance.sub(totalLstBTCManaged)
            : totalLstBTCManaged.sub(currentBalance);
            
        uint256 deviationPercentage = deviation.mul(1e18).div(totalLstBTCManaged);
        
        if (deviationPercentage >= rebalanceThreshold) {
            _rebalance();
        }
    }
    
    /**
     * @dev Execute vault rebalancing
     */
    function _rebalance() internal {
        uint256 currentBalance = lstBTC.balanceOf(address(this));
        totalLstBTCManaged = currentBalance.sub(totalManagementFees).sub(totalPerformanceFees);
        
        emit Rebalanced(currentBalance, totalLstBTCManaged);
    }
    
    /**
     * @dev Manual rebalancing function (only owner)
     */
    function manualRebalance() external onlyOwner {
        _rebalance();
    }
    
    // =============================================================================
    // HELPER FUNCTIONS
    // =============================================================================


    function _calculateWBTCValue(uint256 lstBTCAmount) internal view returns (uint256) {
    uint256 wbtcPrice = priceOracle.getLatestPrice(wbtcToken);
    return lstBTCAmount.mul(wbtcPrice).div(1e18);
}

function _calculateLSTValue(address lstToken, uint256 lstBTCAmount) internal view returns (uint256) {
    uint256 lstPrice = priceOracle.getLatestPrice(lstToken);
    return lstBTCAmount.mul(lstPrice).div(1e18);
}

    
    /**
     * @dev Calculate shares to issue based on lstBTC amount
     * @param lstBTCAmount Amount of lstBTC
     * @return sharesAmount Amount of shares to issue
     */
    function _calculateSharesToIssue(uint256 lstBTCAmount) internal view returns (uint256 sharesAmount) {
        if (totalSupply() == 0) {
            return lstBTCAmount; // 1:1 ratio for first deposit
        }
        
        return lstBTCAmount.mul(totalSupply()).div(totalLstBTCManaged);
    }
    
    /**
     * @dev Add initial supported LSTs
     * @param lstTokens Array of LST token addresses
     */
    function _addInitialLSTs(address[] memory lstTokens) internal {
        for (uint256 i = 0; i < lstTokens.length; i++) {
            address lstToken = lstTokens[i];
            require(lstToken != address(0), "Invalid LST address");
            require(!supportedLSTs[lstToken], "LST already supported");
            
            supportedLSTs[lstToken] = true;
            supportedLSTList.push(lstToken);
        }
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
     /**
     * @dev Get vault Info
     */
   
    function getUserVaultInfo(address user) external view returns (
        uint256 depositedWBTC,
        uint256 depositedLSTValue,
        uint256 lstBTCBalance,
        uint256 yieldEarned,
        uint256 vaultShares,
        uint256 pendingYield
    ) {
        UserInfo storage userInfo_ = userInfo[user];
        uint256 userShares = balanceOf(user);
        uint256 pendingYieldAmount = userShares.mul(accumulatedYieldPerShare).div(1e18).sub(userYieldDebt[user]);
        
        return (
            userInfo_.depositedWBTC,
            userInfo_.depositedLSTValue,
            userInfo_.lstBTCBalance,
            userInfo_.yieldEarned,
            userShares,
            pendingYieldAmount
        );
    }
    
    /**
     * @dev Get vault metrics
     */
    function getVaultMetrics() external view returns (
        uint256 totalManaged,
        uint256 totalYield,
        uint256 totalUsers,
        uint256 currentAPY,
        uint256 totalValueLocked
    ) {
        uint256 lstBTCPrice = priceOracle.getLatestPrice(address(lstBTC));
        uint256 tvl = totalLstBTCManaged.mul(lstBTCPrice).div(1e18);
        uint256 apy = _calculateCurrentAPY();
        
        return (
            totalLstBTCManaged,
            totalYieldGenerated,
            totalDepositors,
            apy,
            tvl
        );
    }
    
    /**
     * @dev Calculate current APY based on recent yield performance
     */
    function _calculateCurrentAPY() internal view returns (uint256) {
        if (totalLstBTCManaged == 0 || totalYieldGenerated == 0) {
            return 0;
        }
        
        uint256 timeElapsed = block.timestamp.sub(lastYieldDistribution);
        if (timeElapsed == 0) {
            return 0;
        }
        
        // Annualized yield rate
        uint256 yieldRate = totalYieldGenerated.mul(SECONDS_PER_YEAR).div(timeElapsed);
        return yieldRate.mul(10000).div(totalLstBTCManaged); // Return in basis points
    }
    
    /**
     * @dev Get supported LST tokens
     */
    function getSupportedLSTs() external view returns (address[] memory) {
        return supportedLSTList;
    }
    
    /**
     * @dev Get conversion rate from custodian
     */
    function getConversionRate(address fromToken, address toToken) external view returns (uint256) {
        return custodian.getConversionRate(fromToken, toToken);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Add support for new LST token
     */
    function addSupportedLST(address lstToken) external onlyOwner {
        require(lstToken != address(0), "Invalid LST address");
        require(!supportedLSTs[lstToken], "LST already supported");
        
        supportedLSTs[lstToken] = true;
        supportedLSTList.push(lstToken);
        
        emit LSTAdded(lstToken);
    }
    
    /**
     * @dev Remove support for LST token
     */
    function removeSupportedLST(address lstToken) external onlyOwner {
        require(supportedLSTs[lstToken], "LST not supported");
        
        supportedLSTs[lstToken] = false;
        
        // Remove from array
        for (uint256 i = 0; i < supportedLSTList.length; i++) {
            if (supportedLSTList[i] == lstToken) {
                supportedLSTList[i] = supportedLSTList[supportedLSTList.length - 1];
                supportedLSTList.pop();
                break;
            }
        }
        
        emit LSTRemoved(lstToken);
    }
    
    /**
     * @dev Update custodian address
     */
    function updateCustodian(address newCustodian) external onlyOwner {
        require(newCustodian != address(0), "Invalid custodian address");
        address oldCustodian = address(custodian);
        custodian = ICustodian(newCustodian);
        
        emit CustodianUpdated(oldCustodian, newCustodian);
    }
    
    /**
     * @dev Update treasury address
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury address");
        treasury = newTreasury;
    }
    
    /**
     * @dev Update rebalancing parameters
     */
    function updateRebalanceParameters(uint256 newThreshold, bool autoRebalance) external onlyOwner {
        require(newThreshold <= 10e16, "Threshold too high"); // Max 10%
        rebalanceThreshold = newThreshold;
        autoRebalanceEnabled = autoRebalance;
    }
    
    /**
     * @dev Emergency pause function
     */
    function emergencyPause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Emergency withdrawal function (only when paused)
     */
    function emergencyWithdraw() external whenPaused {
        uint256 userShares = balanceOf(msg.sender);
        require(userShares > 0, "No shares to withdraw");
        
        uint256 lstBTCAmount = userShares.mul(totalLstBTCManaged).div(totalSupply());
        
        _burn(msg.sender, userShares);
        totalLstBTCManaged = totalLstBTCManaged.sub(lstBTCAmount);
        
        require(lstBTC.transfer(msg.sender, lstBTCAmount), "Emergency withdrawal failed");
        
        emit EmergencyWithdrawal(msg.sender, lstBTCAmount);
    }
}