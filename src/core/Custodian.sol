// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Custodian is ReentrancyGuard, Ownable {
    // 1:1 conversion rates for simplicity
    uint256 public constant WBTCTOLSTBTC_RATE = 1e18;
    uint256 public constant LSTTOLSTBTC_RATE = 1e18;
    uint256 public constant LSTBTCTOWBTC_RATE = 1e18;
    uint256 public constant LSTBTCTOLST_RATE = 1e18;


    constructor () Ownable(msg.sender){}

    event TokensConverted(address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut);

    function convertWBTCToLstBTC(uint256 wbtcAmount) external nonReentrant returns (uint256 lstBTCAmount) {
        lstBTCAmount = (wbtcAmount * WBTCTOLSTBTC_RATE) / 1e18;
        emit TokensConverted(msg.sender, address(this), wbtcAmount, lstBTCAmount);
        return lstBTCAmount;
    }

    function convertLSTToLstBTC(address lstToken, uint256 lstAmount) external nonReentrant returns (uint256 lstBTCAmount) {
        lstBTCAmount = (lstAmount * LSTTOLSTBTC_RATE) / 1e18;
        emit TokensConverted(lstToken, address(this), lstAmount, lstBTCAmount);
        return lstBTCAmount;
    }

    function convertLstBTCToWBTC(uint256 lstBTCAmount) external nonReentrant returns (uint256 wbtcAmount) {
        wbtcAmount = (lstBTCAmount * LSTBTCTOWBTC_RATE) / 1e18;
        emit TokensConverted(address(this), msg.sender, lstBTCAmount, wbtcAmount);
        return wbtcAmount;
    }

    function convertLstBTCToLST(uint256 lstBTCAmount, address lstToken) external nonReentrant returns (uint256 lstAmount) {
        lstAmount = (lstBTCAmount * LSTBTCTOLST_RATE) / 1e18;
        emit TokensConverted(address(this), lstToken, lstBTCAmount, lstAmount);
        return lstAmount;
    }

    function getConversionRate(address fromToken, address toToken) external pure  returns (uint256) {
        if (fromToken == address(0) && toToken == address(0)) {
            return WBTCTOLSTBTC_RATE;
        } else if (fromToken == address(0) && toToken == address(1)) {
            return LSTTOLSTBTC_RATE;
        } else if (fromToken == address(1) && toToken == address(0)) {
            return LSTBTCTOWBTC_RATE;
        } else if (fromToken == address(1) && toToken == address(1)) {
            return LSTBTCTOLST_RATE;
        } else {
            revert("Unsupported token pair");
        }
    }
}
