// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface xIERC20 is IERC20{
     function burn(uint256 value) external;
  
}