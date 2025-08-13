interface IPriceFeed {
    function getLatestPrice(address _tokenAddress) external view returns (uint256);
    function estimate(address token0, address token1, uint256 amount0) external view returns (uint256);
    function getTokenPrice(address _TokenAddress) external view returns (uint256);
}
