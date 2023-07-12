// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.5;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IPriceFeed {
    /**
     * @notice return price of the asset in 18 decimals
     */
    function getLatestPrice(IERC20 _token) external view returns (uint256);
}
