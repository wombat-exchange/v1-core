// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';

import '../interfaces/IRelativePriceProvider.sol';
import './DynamicAsset.sol';

/**
 * @title WstETHAsset for L2 where chainlink price feeds are available

 * @notice Contract presenting an asset in a pool
 * @dev The relative price of an asset may change over time.
 * For example, the ratio of staked BNB : BNB increases as staking reward accrues.
 */
contract WstETHAsset is DynamicAsset {
    AggregatorV3Interface public exchangeRateOracle; // chainlink price feed
    uint256 public maxAge;

    constructor(
        address underlyingToken_,
        string memory name_,
        string memory symbol_,
        AggregatorV3Interface _exchangeRateOracle
    ) DynamicAsset(underlyingToken_, name_, symbol_) {
        exchangeRateOracle = _exchangeRateOracle;
        // Adding 5 minutes buffer to chainlink's trigger parameter (1 day).
        maxAge = 1 days + 5 minutes;
    }

    function setMaxAge(uint96 _maxAge) external onlyOwner {
        maxAge = _maxAge;
    }

    /**
     * @notice get the relative price in WAD
     */
    function getRelativePrice() external view override returns (uint256) {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int256 answer,
            /* uint startedAt */,
            uint256 updatedAt,
            /* uint80 answeredInRound */
        ) = exchangeRateOracle.latestRoundData();
        require(block.timestamp - updatedAt <= maxAge, 'WstETHAsset: chainlink price too old');
        return uint256(answer);
    }
}
