// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./MockV3Aggregator.sol";
/**
 * @title Enhanced TestPriceFeed
 * @notice Price feed contract with both manual and oracle-based price updates
 */
contract TestPriceFeed is OwnerIsCreator {
    // Existing mappings and variables
    mapping(address => uint256) Price;
    mapping(address => bool) isTokenTradeable;
    mapping(address => AggregatorV3Interface) public tokenToAggregator;
    mapping(address => MockV3Aggregator) public tokenToMockAggregator;
    mapping(address => bool) public useOracle; // true = use oracle, false = use manual price
        
    uint256 _decimal = 8;
    uint256 NATIVE_PRICE = 511100000000000000;
   // uint256 BENZ_RATE = 511100000000000000;
    address public NATIVE_TOKEN;
    
    // Events
    event PriceUpdated(address indexed token, uint256 newPrice);
    event OracleSet(address indexed token, address indexed aggregator);
    event MockAggregatorCreated(address indexed token, address indexed mockAggregator);
    
    constructor(
      
    ) {
        NATIVE_TOKEN = address(uint160(uint256(keccak256(abi.encodePacked("ETH"))))); 
    }
    
    /**
     * @notice Create a mock aggregator for a token (testing purposes)
     * @param _tokenAddress Token address
     * @param _initialPrice Initial price for the mock
     * @param _decimals Decimals for the price feed
     */
    function createMockAggregator(
        address _tokenAddress,
        int256 _initialPrice,
        uint8 _decimals
    ) external onlyOwner {
        MockV3Aggregator mockAggregator = new MockV3Aggregator(_decimals, _initialPrice);
        tokenToMockAggregator[_tokenAddress] = mockAggregator;
        tokenToAggregator[_tokenAddress] = AggregatorV3Interface(address(mockAggregator));
        useOracle[_tokenAddress] = true;
        
        emit MockAggregatorCreated(_tokenAddress, address(mockAggregator));
    }
    
    /**
     * @notice Set a real Chainlink aggregator for a token
     * @param _tokenAddress Token address
     * @param _aggregatorAddress Chainlink aggregator address
     */
    function setAggregator(address _tokenAddress, address _aggregatorAddress) external onlyOwner {
        tokenToAggregator[_tokenAddress] = AggregatorV3Interface(_aggregatorAddress);
        useOracle[_tokenAddress] = true;
        
        emit OracleSet(_tokenAddress, _aggregatorAddress);
    }
    
    /**
     * @notice Update price in mock aggregator
     * @param _tokenAddress Token address
     * @param _newPrice New price to set
     */
    function updateMockPrice(address _tokenAddress, int256 _newPrice) external onlyOwner {
        require(address(tokenToMockAggregator[_tokenAddress]) != address(0), "Mock aggregator not set");
        tokenToMockAggregator[_tokenAddress].updateAnswer(_newPrice);
        
        emit PriceUpdated(_tokenAddress, uint256(_newPrice));
    }
    
    /**
     * @notice Toggle between oracle and manual price for a token
     * @param _tokenAddress Token address
     * @param _useOracle True to use oracle, false to use manual price
     */
    function togglePriceSource(address _tokenAddress, bool _useOracle) external onlyOwner {
        useOracle[_tokenAddress] = _useOracle;
    }
    
    /**
     * @notice Get the latest price from oracle or manual setting
     * @param _tokenAddress Token address
     * @return Latest price
     */
    function getLatestPrice(address _tokenAddress) public view returns (uint256) {
        if (useOracle[_tokenAddress] && address(tokenToAggregator[_tokenAddress]) != address(0)) {
            (, int256 price, , ,) = tokenToAggregator[_tokenAddress].latestRoundData();
            require(price > 0, "Invalid price from oracle");
            return uint256(price);
        } else {
            return Price[_tokenAddress];
        }
    }
    
    /**
     * @notice Enhanced getTokenPrice that uses oracle when available
     */
    function getTokenPrice(address _TokenAddress) public view returns (uint256) {
        return getLatestPrice(_TokenAddress);
    }
    

   

    function getExchangeRate(
        address baseAddress, 
        address quoteAddress
    ) internal view returns (int256) {
        require(_decimal > uint8(0) && _decimal <= uint8(18), "Unsupported Decimals");

        uint256 _decimals = 10**_decimal;
        uint256 basePrice = getLatestPrice(baseAddress); // Now uses oracle when available
        uint256 baseDecimals = 18;
        int256 _basePrice = scalePrice(basePrice, baseDecimals, _decimal);

        uint256 quotePrice = getLatestPrice(quoteAddress); // Now uses oracle when available
        uint256 quoteDecimals = 18;
        int256 _quotePrice = scalePrice(quotePrice, quoteDecimals, _decimal);

        return (_basePrice * int256(_decimals)) / _quotePrice;
    }
 
    function scalePrice(
        uint256 _price,
        uint256 _priceDecimals,
        uint256 _decimals
    ) private pure returns (int256) {
        if (_priceDecimals < _decimals) {
            return int256(_price * 10**(_decimals - _priceDecimals));
        } else if (_priceDecimals > _decimals) {
            return int256(_price / 10**(_priceDecimals - _decimals));
        }
        return int256(_price);
    }

    function estimate(
        address token0,
        address token1,
        uint256 amount0
    ) external view returns (uint256) {
        int256 _rate = getExchangeRate(token0, token1);
        return (amount0 * uint256(_rate)) / (10 ** 8);
    }

    function getNativeToken() external view returns (address) {
        return NATIVE_TOKEN;
    }
    
    /**
     * @notice Get aggregator address for a token
     */
    function getAggregator(address _tokenAddress) external view returns (address) {
        return address(tokenToAggregator[_tokenAddress]);
    }
    
    /**
     * @notice Check if token uses oracle for pricing
     */
    function isUsingOracle(address _tokenAddress) external view returns (bool) {
        return useOracle[_tokenAddress];
    }
}