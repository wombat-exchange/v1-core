// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '../interfaces/IPriceFeed.sol';

/**
 * @title Chainlink Price Feed
 * @notice Contract to get the latest prices for multiple tokens from Chainlink
 */
abstract contract OraclePriceFeed is IPriceFeed, Ownable {
    /// @notice the fallback price feed in case the price is not available on Pyth
    IPriceFeed public fallbackPriceFeed;
    uint256 public maxPriceAgeBound;

    event SetMaxPriceAgeBound(uint256 maxPriceAgeBound);
    event UpdateFallbackPriceFeed(IPriceFeed priceFeed);

    constructor(uint256 _maxPriceAgeBound) {
        setMaxPriceAgeBound(_maxPriceAgeBound);
    }

    function _getFallbackPrice(IERC20 _token) internal view returns (uint256 price) {
        if (fallbackPriceFeed != IPriceFeed(address(0))) {
            return fallbackPriceFeed.getLatestPrice(_token);
        } else {
            revert('Price is too old');
        }
    }

    function setFallbackPriceFeed(IPriceFeed _fallbackPriceFeed) external onlyOwner {
        fallbackPriceFeed = _fallbackPriceFeed;
        emit UpdateFallbackPriceFeed(_fallbackPriceFeed);
    }

    function setMaxPriceAgeBound(uint256 _maxPriceAgeBound) public onlyOwner {
        maxPriceAgeBound = _maxPriceAgeBound;
        emit SetMaxPriceAgeBound(_maxPriceAgeBound);
    }

    uint256[50] private __gap;
}
