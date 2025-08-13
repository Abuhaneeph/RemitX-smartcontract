// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
* @dev Interface for lstBTC token
*/
interface ILstBTC is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function getVotingPower(address user) external view returns (uint256);
}
