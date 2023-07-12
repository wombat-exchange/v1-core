// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '../interfaces/IRelativePriceProvider.sol';
import '../interfaces/IPriceFeed.sol';
import './Asset.sol';

/**
 * @title Asset with Price Feed
 * @notice Contract presenting an asset in a pool
 * @dev The relative price of an asset may change over time.
 * For example, the ratio of staked BNB : BNB increases as staking reward accrues.
 */
contract PriceFeedAsset is Asset, IRelativePriceProvider {
    IPriceFeed public priceFeed;

    event SetPriceFeed(IPriceFeed priceFeed);

    constructor(
        IERC20 underlyingToken_,
        string memory name_,
        string memory symbol_
    ) Asset(address(underlyingToken_), name_, symbol_) {}

    function setPriceFeed(IPriceFeed _priceFeed) external onlyOwner {
        require(address(_priceFeed) != address(0), 'zero addr');
        priceFeed = _priceFeed;

        emit SetPriceFeed(_priceFeed);
    }

    /**
     * @notice get the relative price in WAD
     */
    function getRelativePrice() external view virtual returns (uint256) {
        return priceFeed.getLatestPrice(IERC20(underlyingToken));
    }
}
