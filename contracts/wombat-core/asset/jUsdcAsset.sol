// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '../interfaces/IRelativePriceProvider.sol';
import './DynamicAsset.sol';

interface IjUsdc {
    function getUSDCRatio(uint256 _jUSDC) external view returns (uint256); // return USDC ratio in 6 decimals
}

/**
 * @title Asset with Dynamic Price
 * @notice Contract presenting an asset in a pool
 * @dev The relative price of an asset may change over time.
 * For example, the ratio of staked BNB : BNB increases as staking reward accrues.
 */
contract jUsdcAsset is DynamicAsset {
    IjUsdc exchangeRateOracle;

    constructor(
        address underlyingToken_,
        string memory name_,
        string memory symbol_,
        IjUsdc _exchangeRateOracle
    ) DynamicAsset(underlyingToken_, name_, symbol_) {
        exchangeRateOracle = _exchangeRateOracle;
    }

    /**
     * @notice get the relative price in WAD
     */
    function getRelativePrice() external view override returns (uint256) {
        return exchangeRateOracle.getUSDCRatio(1e18) * 1e12; // scale up from 6 decimals to 18 decimals
    }
}
