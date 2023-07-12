// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';

import './OraclePriceFeed.sol';

/**
 * @title Chainlink Price Feed
 * @notice Contract to get the latest prices for multiple tokens from Chainlink
 */
contract ChainlinkPriceFeed is OraclePriceFeed {
    mapping(IERC20 => AggregatorV3Interface) public usdPriceFeeds;
    mapping(IERC20 => uint256) public maxPriceAge;

    event UpdatePriceFeed(IERC20 token, AggregatorV3Interface priceFeed, uint256 maxPriceAge);

    constructor(uint256 _maxPriceAgeBound) OraclePriceFeed(_maxPriceAgeBound) {}

    /**
     * Returns the latest price.
     */
    function getLatestPrice(IERC20 _token) external view returns (uint256 price) {
        AggregatorV3Interface priceFeed = usdPriceFeeds[_token];
        // prettier-ignore
        (
            /* uint80 roundID */,
            int256 answer,
            /* uint startedAt */,
            uint256 updatedAt,
            /* uint80 answeredInRound */
        ) = priceFeed.latestRoundData();

        if (block.timestamp - updatedAt > maxPriceAge[_token]) {
            return _getFallbackPrice(_token);
        } else {
            require(answer > 0);
            return (uint256(answer) * 1e18) / 10 ** (priceFeed.decimals());
        }
    }

    function setChainlinkUsdPriceFeed(
        IERC20 _token,
        AggregatorV3Interface _priceFeed,
        uint256 _maxPriceAge
    ) external onlyOwner {
        require(_maxPriceAge <= maxPriceAgeBound, 'invalid _maxPriceAge');
        usdPriceFeeds[_token] = _priceFeed;
        maxPriceAge[_token] = _maxPriceAge;
        emit UpdatePriceFeed(_token, _priceFeed, _maxPriceAge);
    }
}
