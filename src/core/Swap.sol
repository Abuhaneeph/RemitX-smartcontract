// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;

import {Events} from "../libraries/Events.sol";
import {xIERC20} from "../interfaces/xIERC20.sol";
import {TestPriceFeed} from "../feeds/TestPriceFeed.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";

//NATIVE TOKEN 0xdcc703c0E500B653Ca82273B7BFAd8045D85a470
//PRICE FEED 0x48686EA995462d611F4DA0d65f90B21a30F259A5
// SWAP 0xC0c182d9895882C61C1fC1DF20F858e5E29a4f71
//SAVING 0xC0c182d9895882C61C1fC1DF20F858e5E29a4f71
//AFX 0xCcD4D22E24Ab5f9FD441a6E27bC583d241554a3c
//USDT 0x6765e788d5652E22691C6c3385c401a9294B9375
//WETH 0x25a8e2d1e9883D1909040b6B3eF2bb91feAB2e2f
//AFR 0xC7d68ce9A8047D4bF64E6f7B79d388a11944A06E
//cNGN 0x48D2210bd4E72c741F74E6c0E8f356b2C36ebB7A
//cGHS 0x8F11F588B1Cc0Bc88687F7d07d5A529d34e5CD84
//cZAR 0x7dd1aD415F58D91BbF76BcC2640cc6FdD44Aa94b
//cKES 0xaC56E37f70407f279e27cFcf2E31EdCa888EaEe4
/**
 * @title AfriCoin Swap Contract
 * @dev Decentralized exchange contract for token swapping and liquidity provision on LISK network
 * @notice This contract allows users to swap tokens, provide liquidity, and earn rewards using ETH as native token
 * @author AfriCoin Team
 */
contract Swap is OwnerIsCreator {
    
    // ============ EVENTS ============
    
    /**
     * @dev Emitted when the contract receives native ETH tokens
     * @param sender Address that sent the ETH
     * @param amount Amount of ETH received in wei
     */
    event Received(address sender, uint amount);

    // ============ RECEIVE FUNCTION ============
    
    /**
     * @dev Allows contract to receive native ETH tokens
     * @notice Automatically called when ETH is sent to the contract
     */
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
    
    // ============ STATE VARIABLES ============
    
    /// @dev Price feed oracle contract for token price calculations
    TestPriceFeed private priceAPI;
    
    /// @dev Platform accumulated profits in AfriCoin tokens
    uint256 private _platformProfit;
    
    /// @dev Accumulated fees designated for burning
    uint256 private _burnableFees;

    /// @dev Swap fee percentage (0.02% = 20 basis points)
    uint private swapFee = 20;
    

    /// @dev Unique identifier counter for pools
    uint256 private POOL_ID;
    
    /// @dev Unique identifier counter for liquidity positions
    uint256 private LIQUID_ID;
    
    /// @dev Unique identifier counter for providers
    uint256 private PROVIDER_ID;

    /// @dev Address of the AfriCoin token contract
    address public AFRI_COIN;
 
    // ============ MAPPINGS ============
    
    /// @dev Maps pool ID to Pool struct
    mapping(uint => Pool) public pools;
    
    /// @dev Maps provider address to Provider struct
    mapping(address => Provider) public providers;
    
    /// @dev Maps liquid ID to Liquid struct
    mapping(uint => Liquid) public liquids;

    // ============ STRUCTS ============

    /**
     * @dev Represents a liquidity pool containing two tokens
     * @param id Unique identifier for the pool
     * @param token0 Address of the first token in the pair
     * @param token1 Address of the second token in the pair
     * @param liquids Array of liquid IDs belonging to this pool
     */
    struct Pool {
        uint id;
        address token0;
        address token1;
        uint[] liquids;
    }

    /**
     * @dev Represents a liquidity position provided by a user
     * @param id Unique identifier for the liquid position
     * @param poolId ID of the pool this liquid belongs to
     * @param amount0 Amount of token0 in the position
     * @param amount1 Amount of token1 in the position
     * @param provider Address of the liquidity provider
     */
    struct Liquid {
        uint id;
        uint poolId;
        uint256 amount0;
        uint256 amount1;
        address provider;
    }

    /**
     * @dev Represents a liquidity provider's profile
     * @param id Unique identifier for the provider
     * @param totalEarned Total rewards earned by the provider
     * @param balance Current available balance for withdrawal
     * @param autoStake Whether to automatically stake rewards
     * @param liquids Array of liquid IDs owned by this provider
     */
    struct Provider {
        uint id;
        uint256 totalEarned;
        uint256 balance;
        bool autoStake;
        uint[] liquids;
    }

    // ============ CONSTRUCTOR ============

    /**
     * @dev Initializes the swap contract with price feed and AfriCoin token
     * @param _priceAPI Address of the price feed oracle contract
     * @param _AFRI_COIN Address of the AfriCoin token contract
     */
    constructor(address _priceAPI, address _AFRI_COIN) {
        // Initialize the price feed oracle
        priceAPI = TestPriceFeed(_priceAPI);

        // Set the AfriCoin token address
        AFRI_COIN = _AFRI_COIN;

        // Create initial pool for ETH/AfriCoin pair
        _createPool(priceAPI.getNativeToken(), _AFRI_COIN);
    }

    // ============ PUBLIC VIEW FUNCTIONS ============

    /**
     * @dev Returns the total liquidity size for a token pair
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @return amount0 Total amount of token0 in the pool
     * @return amount1 Total amount of token1 in the pool
     */
    function getPoolSize(
        address token0,
        address token1
    ) public view returns (uint256, uint256) {
        uint poolId = _findPool(token0, token1);
        return _poolSize(poolId);
    }

    /**
     * @dev Estimates the output amount for a token swap
     * @param token0 Address of the input token
     * @param token1 Address of the output token
     * @param amount0 Amount of input token in wei
     * @return Estimated amount of output token
     */
    function estimate(
        address token0,
        address token1,
        uint256 amount0
    ) public view returns (uint256) {
        uint256 _rate = priceAPI.estimate(token0, token1, amount0);
        return _rate;
    }

    /**
     * @dev Returns the address of this contract
     * @return Address of the swap contract
     */
    function getContractAddress() public view returns (address) {
        return address(this);
    }

    /**
     * @dev Finds a pool ID for a given token pair
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @return Pool ID if found, 0 if not found
     */
    function findPool(address token0, address token1) public view returns (uint256) {
        return _findPool(token0, token1);
    }

    /**
     * @dev Gets the liquid ID for a provider in a specific pool
     * @param pool_id ID of the pool to check
     * @return Liquid ID if found, 0 if not found
     */
    function liquidIndex(uint256 pool_id) public view returns (uint256) {
        return _liquidIndex(pool_id, msg.sender);
    } 

      /**
     * @dev Gets Current Pool ID created
 
     */

    function getPoolId () public view returns (uint256) {
        return POOL_ID;
    }

    /**
     * @dev Returns the current burnable fees balance (owner only)
     * @return Amount of fees available for burning
     */
    function getBurnableFeesBal() public view onlyOwner returns (uint256) {
        return _burnableFees;
    }

    // ============ PROVIDER FUNCTIONS ============

    /**
     * @dev Registers a new liquidity provider account
     * @notice Can only be called by addresses that are not already providers
     */
    function unlockedProviderAccount() public onlyGuest {
        // Create new unique provider ID
        PROVIDER_ID++;

        // Initialize provider with default values
        providers[msg.sender] = Provider(
            PROVIDER_ID,
            providers[msg.sender].totalEarned,
            providers[msg.sender].balance,
            false,
            providers[msg.sender].liquids
        );
    }

    /**
     * @dev Updates provider's auto-staking preference
     * @param _autoStake Whether to automatically stake rewards
     */
    function updateProviderProfile(bool _autoStake) public onlyProvider {
        providers[msg.sender].autoStake = _autoStake;
    }

    /**
     * @dev Allows provider to withdraw their earned rewards
     * @param amount Amount of AfriCoin tokens to withdraw
     */
    function withDrawEarnings(uint256 amount) public onlyProvider {
        require(
            providers[msg.sender].balance >= amount,
            "Insufficient Balance"
        );

        // Transfer AfriCoin rewards to provider
        xIERC20(AFRI_COIN).transfer(msg.sender, amount);

        // Update provider balance
        providers[msg.sender].balance -= amount;
    }

    // ============ SWAPPING FUNCTIONS ============

    /**
     * @dev Swaps tokens for the caller
     * @param token0 Address of the input token
     * @param token1 Address of the output token
     * @param amount0 Amount of input token to swap
     * @return Amount of output token received
     */
    function swap(
        address token0,
        address token1,
        uint256 amount0
    ) public payable returns (uint256) {
        return doSwap(token0, token1, amount0, msg.sender);
    }

    /**
     * @dev Performs token swap with detailed validation and fee handling
     * @param token0 Address of the input token
     * @param token1 Address of the output token
     * @param amount0 Amount of input token to swap
     * @param user Address receiving the swapped tokens
     * @return amount1 Amount of output token received
     */
    function doSwap(
        address token0,
        address token1,
        uint256 amount0,
        address user
    ) public payable returns (uint256) {
        require(amount0 >= 100, "Amount to swap cannot be lesser than 100 WEI");

        uint256 amount1;
        uint256 _safeAmount0 = amount0;

        // Find the pool for this token pair
        uint poolId = _findPool(token0, token1);
        require(pools[poolId].id > 0, "Pool does not exists");

        // Handle ETH => ERC20 swaps
        if (token0 == priceAPI.getNativeToken()) {
            require(msg.value >= 100, "Native Currency cannot be lesser than 100 WEI");
            
            _safeAmount0 = msg.value;
            amount1 = estimate(token0, token1, _safeAmount0);

            // Verify sufficient pool liquidity
            (, uint256 poolSizeToken1) = _poolSize(poolId);
            require(poolSizeToken1 >= amount1, "Insufficient Pool Size");

            // Process swap and calculate fees
            uint256 fee = _transferSwappedTokens0(
                pools[poolId].token1,
                amount1,
                user
            );

            // Distribute fees: 80% to providers, 3% for burning, 17% platform profit
            uint256 providersReward = ((fee * 80) / 100);
            uint256 burnFee = ((fee * 3) / 100);
            _burnableFees += burnFee;
            uint256 contractProfit = fee - providersReward - burnFee;
            _platformProfit += contractProfit;

            // Update liquidity positions
            _aggregateLiquids(
                _safeAmount0,
                amount1,
                poolSizeToken1,
                pools[poolId],
                providersReward
            );
        }
        // Handle ERC20 => ETH swaps
        else if (token1 == priceAPI.getNativeToken()) {
            amount1 = estimate(token0, token1, _safeAmount0);

            // Verify sufficient pool liquidity
            (uint256 poolSizeToken1, ) = _poolSize(poolId);
            require(poolSizeToken1 >= amount1, "Insufficient Pool Size");

            // Process swap and calculate fees
            uint256 fee = _transferSwappedTokens1(
                pools[poolId].token0,
                _safeAmount0,
                amount1,
                user
            );

            // Distribute fees
            uint256 providersReward = ((fee * 80) / 100);
            uint256 burnFee = ((fee * 3) / 100);
            _burnableFees += burnFee;
            uint256 contractProfit = fee - providersReward - burnFee;
            _platformProfit += contractProfit;

            // Update liquidity positions
            _aggregateLiquids(
                _safeAmount0,
                amount1,
                poolSizeToken1,
                pools[poolId],
                providersReward
            );
        }
        // Handle ERC20 => ERC20 swaps
        else {
            amount1 = estimate(token0, token1, _safeAmount0);
            
            // Determine correct pool size based on token position
            uint256 poolSizeToken1;
            if (pools[poolId].token0 == token1) {
                (uint256 _poolSizeToken1, ) = _poolSize(poolId);
                poolSizeToken1 = _poolSizeToken1;
            } else if (pools[poolId].token1 == token1) {
                (, uint256 _poolSizeToken1) = _poolSize(poolId);
                poolSizeToken1 = _poolSizeToken1;
            }

            require(poolSizeToken1 >= amount1, "Insufficient Pool Size");

            // Process swap and calculate fees
            uint256 fee = _transferSwappedTokens2(
                token0,
                token1,
                _safeAmount0,
                amount1,
                user
            );

            // Distribute fees
            uint256 providersReward = ((fee * 80) / 100);
            uint256 burnFee = ((fee * 3) / 100);
            _burnableFees += burnFee;
            uint256 contractProfit = fee - providersReward - burnFee;
            _platformProfit += contractProfit;

            // Update liquidity positions
            _aggregateLiquids(
                _safeAmount0,
                amount1,
                poolSizeToken1,
                pools[poolId],
                providersReward
            );
        }

        // Emit swap event for on-chain tracking
        emit Events.FleepSwaped(
            amount0,
            amount1,
            token0,
            token1,
            block.timestamp
        );

        return amount1;
    }

    // ============ LIQUIDITY PROVIDER FUNCTIONS ============

    /**
     * @dev Provides liquidity to a specified pool
     * @param poolId ID of the pool to provide liquidity to
     * @param amount0 Amount of token0 to provide
     */
    function provideLiquidity(
        uint poolId,
        uint256 amount0
    ) public payable {
        require(amount0 >= 100, "Amount cannot be lesser than 100 WEI");

        uint256 amount1;
        uint256 _safeAmount0 = amount0;

        // Auto-register as provider if not already registered
        if (providers[msg.sender].id == 0) {
            unlockedProviderAccount();
        }

        // Handle ETH token provision
        if (pools[poolId].token0 == priceAPI.getNativeToken()) {
            require(msg.value > 100, "ETH cannot be lesser than 100 WEI");
            
            _safeAmount0 = msg.value;
            // Calculate required amount of paired token
            amount1 = estimate(
                pools[poolId].token0,
                pools[poolId].token1,
                _safeAmount0
            );

            // Transfer paired token from provider to contract
            xIERC20(pools[poolId].token1).transferFrom(
                msg.sender,
                address(this),
                amount1
            );
        } else {
            // Calculate required amount of paired token
            amount1 = estimate(
                pools[poolId].token0,
                pools[poolId].token1,
                _safeAmount0
            );
            
            // Transfer both tokens from provider to contract
            xIERC20(pools[poolId].token0).transferFrom(
                msg.sender,
                address(this),
                _safeAmount0
            );
            xIERC20(pools[poolId].token1).transferFrom(
                msg.sender,
                address(this),
                amount1
            );
        }

        // Check if provider already has liquidity in this pool
        uint liquidId = _liquidIndex(poolId, msg.sender);

        if (liquidId > 0) {
            // Update existing liquidity position
            liquids[liquidId].amount0 += _safeAmount0;
            liquids[liquidId].amount1 += amount1;
        } else {
            // Create new liquidity position
            _createLiquid(poolId, _safeAmount0, amount1, msg.sender);
        }

        // Emit liquidity provision event
        emit Events.LiquidProvided(
            pools[poolId].token0,
            pools[poolId].token1,
            _safeAmount0,
            amount1,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @dev Removes liquidity from a pool and returns tokens to provider
     * @param id ID of the liquidity position to remove
     */
    function removeLiquidity(uint id) public onlyProvider {
        require(liquids[id].provider == msg.sender, "Unauthorized");
    
        // Get pool information
        uint poolId = liquids[id].poolId;
        Pool memory pool = pools[poolId];

        // Return tokens to provider based on pool type
        if (pools[poolId].token0 == priceAPI.getNativeToken()) {
            // Return ETH and ERC20 token
            payable(msg.sender).transfer(liquids[id].amount0);
            xIERC20(pool.token1).transfer(msg.sender, liquids[id].amount1);
        } else {
            // Return both ERC20 tokens
            xIERC20(pool.token0).transfer(msg.sender, liquids[id].amount0);
            xIERC20(pool.token1).transfer(msg.sender, liquids[id].amount1);
        }

        // Remove liquid ID from pool's liquids array
        for (uint index = 0; index < pools[poolId].liquids.length; index++) {
            if (liquids[pools[poolId].liquids[index]].provider == msg.sender) {
                delete pools[poolId].liquids[index];
            }
        }

        // Remove liquid ID from provider's liquids array
        for (uint index = 0; index < providers[msg.sender].liquids.length; index++) {
            if (liquids[providers[msg.sender].liquids[index]].poolId == pool.id) {
                delete providers[msg.sender].liquids[index];
            }
        }

        // Delete the liquidity position
        delete liquids[id];
    }

    /**
     * @dev Returns all liquidity positions for a given wallet
     * @param wallet Address of the wallet to query
     * @return _pools Array of pool IDs
     * @return _amounts0 Array of token0 amounts
     * @return _amounts1 Array of token1 amounts
     * @return providerLiquids Array of liquid IDs
     */
    function myLiquidities(
        address wallet
    )
        public
        view
        returns (
            uint256[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        uint256[] memory providerLiquids = providers[wallet].liquids;

        uint256[] memory _pools = new uint256[](providerLiquids.length);
        uint256[] memory _amounts0 = new uint256[](providerLiquids.length);
        uint256[] memory _amounts1 = new uint256[](providerLiquids.length);

        for (uint index; index < providerLiquids.length; index++) {
            _pools[index] = liquids[providerLiquids[index]].poolId;
            _amounts0[index] = liquids[providerLiquids[index]].amount0;
            _amounts1[index] = liquids[providerLiquids[index]].amount1;
        }

        return (_pools, _amounts0, _amounts1, providerLiquids);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Creates a new trading pool for a token pair (owner only)
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @return Pool ID of the created pool
     */
    function createPool(
        address token0,
        address token1
    ) public onlyOwner returns (uint) {
        return _createPool(token0, token1);
    }

    /**
     * @dev Updates the swap fee percentage (owner only)
     * @param fee New fee in basis points (20 = 0.20%)
     */
    function updateSwapFee(uint fee) public onlyOwner {
        require(fee > 0, "Platform fee cannot be zero");
        require(fee < 1000, "Platform fee cannot be a hundred");
        swapFee = fee;
    }

    /**
     * @dev Withdraws platform earnings to specified address (owner only)
     * @param amount Amount of AfriCoin tokens to withdraw
     * @param receiver Address to receive the tokens
     */
    function withDrawPlaformEarnings(
        uint256 amount,
        address receiver
    ) public onlyOwner {
        require(_platformProfit >= amount, "Insufficient Balance");

        // Transfer AfriCoin tokens to receiver
        xIERC20(AFRI_COIN).transfer(receiver, amount);
        _platformProfit -= amount;
    }

    /**
     * @dev Burns accumulated fees by destroying AfriCoin tokens (owner only)
     */
    function burnFees() public onlyOwner {
        require(getBurnableFeesBal() > 0, "Insufficient Balance");
        
        // Burn the accumulated fees
        xIERC20(AFRI_COIN).burn(_burnableFees);
        _burnableFees -= getBurnableFeesBal();
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Finds the liquid ID for a provider in a specific pool
     * @param poolId ID of the pool
     * @param provider Address of the provider
     * @return Liquid ID if found, 0 if not found
     */
    function _liquidIndex(
        uint poolId,
        address provider
    ) private view returns (uint) {
        uint256[] memory providerLiquids = providers[provider].liquids;

        for (uint index = 0; index < providerLiquids.length; index++) {
            if (liquids[providerLiquids[index]].poolId == poolId) {
                return providerLiquids[index];
            }
        }

        return 0;
    }

    /**
     * @dev Distributes swap impact and rewards across all liquidity providers
     * @param amount0 Amount of token0 being swapped
     * @param amount1 Amount of token1 being swapped
     * @param poolSizeToken1 Total size of token1 in the pool
     * @param pool Pool struct containing liquidity information
     * @param fee Total fee to distribute to providers
     */
    function _aggregateLiquids(
        uint256 amount0,
        uint256 amount1,
        uint256 poolSizeToken1,
        Pool memory pool,
        uint256 fee
    ) private {
        // Distribute swap impact proportionally across all providers
        for (uint index = 0; index < pool.liquids.length; index++) {
            uint liquidId = pool.liquids[index];

            // Calculate provider's share of rewards based on their contribution
            uint256 reward = ((liquids[liquidId].amount1 * fee) / poolSizeToken1);

            address provider = liquids[liquidId].provider;

            // Calculate proportional addition to token0
            uint256 additionAmount = ((liquids[liquidId].amount1 * amount0) / poolSizeToken1);
            liquids[liquidId].amount0 += additionAmount;

            // Calculate proportional deduction from token1
            uint256 deductionAmount = ((liquids[liquidId].amount1 * amount1) / poolSizeToken1);
            liquids[liquidId].amount1 -= deductionAmount;

            // Update provider rewards
            providers[provider].totalEarned += reward;
            providers[provider].balance += reward;
        }
    }

    /**
     * @dev Handles ETH => ERC20 token transfers and fee calculation
     * @param token1 Address of the output ERC20 token
     * @param amount1 Amount of output token to transfer
     * @param owner Address receiving the tokens
     * @return Fee amount in AfriCoin tokens
     */
    function _transferSwappedTokens0(
        address token1,
        uint256 amount1,
        address owner
    ) private returns (uint256) {
        xIERC20 quoteToken = xIERC20(token1);

        // Calculate swap fee
        uint256 _fee = ((amount1 / 1000) * swapFee);

        // Transfer tokens minus fee to user
        quoteToken.transfer(owner, (amount1 - _fee));

        // Convert fee to AfriCoin equivalent
        return estimate(token1, AFRI_COIN, _fee);
    }

    /**
     * @dev Handles ERC20 => ETH token transfers and fee calculation
     * @param token0 Address of the input ERC20 token
     * @param amount0 Amount of input token
     * @param amount1 Amount of ETH to transfer
     * @param owner Address receiving the ETH
     * @return Fee amount in AfriCoin tokens
     */
    function _transferSwappedTokens1(
        address token0,
        uint256 amount0,
        uint256 amount1,
        address owner
    ) public payable returns (uint256) {
        xIERC20 baseToken = xIERC20(token0);

        // Calculate swap fee
        uint256 _fee = ((amount1 / 1000) * swapFee);

        // Transfer input token from user to contract
        baseToken.transferFrom(owner, address(this), amount0);

        // Verify contract has sufficient ETH balance
        require(
            address(this).balance >= amount1,
            "Contract: Insufficient Balance"
        );

        // Transfer ETH minus fee to user
        (bool sent, ) = owner.call{value: amount1 - _fee}("");
        require(sent, "Failed to send ETH to the User");

        // Convert fee to AfriCoin equivalent
        return estimate(priceAPI.getNativeToken(), AFRI_COIN, _fee);
    }

    /**
     * @dev Handles ERC20 => ERC20 token transfers and fee calculation
     * @param token0 Address of the input token
     * @param token1 Address of the output token
     * @param amount0 Amount of input token
     * @param amount1 Amount of output token
     * @param owner Address receiving the output tokens
     * @return Fee amount in AfriCoin tokens
     */
    function _transferSwappedTokens2(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address owner
    ) private returns (uint256) {
        xIERC20 baseToken = xIERC20(token0);
        xIERC20 quoteToken = xIERC20(token1);

        // Calculate swap fee
        uint256 _fee = ((amount1 / 1000) * swapFee);

        // Transfer input token from user to contract
        baseToken.transferFrom(owner, address(this), amount0);

        // Transfer output token minus fee to user
        quoteToken.transfer(owner, (amount1 - _fee));

        // Convert fee to AfriCoin equivalent
        return estimate(token1, AFRI_COIN, _fee);
    }

    /**
     * @dev Converts amount to wei (internal utility function)
     * @param amount Amount to convert
     * @return Amount in wei
     */
    function _inWei(uint256 amount) private pure returns (uint256) {
        return amount * 10 ** 18;
    }

    /**
     * @dev Finds a pool ID for a given token pair
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @return Pool ID if found, 0 if not found
     */
    function _findPool(
        address token0,
        address token1
    ) private view returns (uint) {
        require(
            token0 != address(0) && token1 != address(0),
            "Invalid Pool Tokens"
        );
        
        for (uint index = 0; index <= POOL_ID; index++) {
            // Check both token arrangements (A/B and B/A)
            if (
                (pools[index].token0 == token0 && pools[index].token1 == token1) ||
                (pools[index].token0 == token1 && pools[index].token1 == token0)
            ) {
                return index;
            }
        }
        return 0;
    }

    /**
     * @dev Creates a new liquidity position
     * @param poolId ID of the pool
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @param provider Address of the liquidity provider
     */
    function _createLiquid(
        uint poolId,
        uint256 amount0,
        uint256 amount1,
        address provider
    ) private {
        LIQUID_ID++;
        
        // Create the liquidity position
        liquids[LIQUID_ID] = Liquid(
            LIQUID_ID,
            poolId,
            amount0,
            amount1,
            provider
        );
        
        // Register the liquid in pool and provider records
        pools[poolId].liquids.push(LIQUID_ID);
        providers[provider].liquids.push(LIQUID_ID);
    }

    /**
     * @dev Calculates the total size of a liquidity pool
     * @param id Pool ID
     * @return amount0 Total amount of token0 in the pool
     * @return amount1 Total amount of token1 in the pool
     */
    function _poolSize(uint id) private view returns (uint256, uint256) {
        uint256 amount0;
        uint256 amount1;
        
        for (uint index = 0; index < pools[id].liquids.length; index++) {
            uint liquidId = pools[id].liquids[index];
            amount0 += liquids[liquidId].amount0;
            amount1 += liquids[liquidId].amount1;
        }
        
        return (amount0, amount1);
    }

    /**
     * @dev Creates a new liquidity pool for a token pair
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @return Pool ID of the created pool, 0 if pool already exists
     */
    function _createPool(
        address token0,
        address token1
    ) private returns (uint) {
        require(
            token0 != address(0),
            "Pair does not exists, Contact admin"
        );
        require(
            token1 != address(0),
            "Pair does not exists, Contact admin"
        );

        // Check if pool already exists
        bool exists = _findPool(token0, token1) != 0;
        if (exists) return 0;

        POOL_ID++;
        Pool memory pool = pools[POOL_ID];

        // Create new pool with empty liquids array
        pools[POOL_ID] = Pool(POOL_ID, token0, token1, pool.liquids);

        return POOL_ID;
    }

    // ============ MODIFIERS ============

    /**
     * @dev Restricts access to addresses that are not registered as providers
     */
    modifier onlyGuest() {
        require(providers[msg.sender].id == 0, "Only Guest");
        _;
    }

    /**
     * @dev Restricts access to registered liquidity providers only
     */
    modifier onlyProvider() {
        require(providers[msg.sender].id != 0, "Only Provider");
        _;
    }
}