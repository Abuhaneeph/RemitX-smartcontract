// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ICustodian {
    function convertWBTCToLstBTC(uint256 wbtcAmount) external returns (uint256 lstBTCAmount);
    function convertLSTToLstBTC(address lstToken, uint256 lstAmount) external returns (uint256 lstBTCAmount);
    function convertLstBTCToWBTC(uint256 lstBTCAmount) external returns (uint256 wbtcAmount);
    function convertLstBTCToLST(uint256 lstBTCAmount, address lstToken) external returns (uint256 lstAmount);
    function getConversionRate(address fromToken, address toToken) external view returns (uint256);
}