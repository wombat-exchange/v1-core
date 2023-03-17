// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '../interfaces/IRelativePriceProvider.sol';
import './DynamicAsset.sol';

struct ExchangeRateData {
    uint256 totalWei; // total amount of BNB managed by the pool
    uint256 poolTokenSupply; // total amount of stkBNB managed by the pool
}

interface IStakePool {
    function exchangeRate() external view returns (ExchangeRateData memory);
}

/**
 * @title Asset with Dynamic Price
 * @notice Contract presenting an asset in a pool
 * @dev The relative price of an asset may change over time.
 * For example, the ratio of staked BNB : BNB increases as staking reward accrues.
 */
contract StkbnbAsset is DynamicAsset {
    IStakePool exchangeRateOracle;

    constructor(
        address underlyingToken_,
        string memory name_,
        string memory symbol_,
        IStakePool _exchangeRateOracle
    ) DynamicAsset(underlyingToken_, name_, symbol_) {
        exchangeRateOracle = _exchangeRateOracle;
    }

    /**
     * @notice get the relative price in WAD
     */
    function getRelativePrice() external view override returns (uint256) {
        ExchangeRateData memory data = exchangeRateOracle.exchangeRate();
        return (data.totalWei * 1e18) / data.poolTokenSupply;
    }
}
