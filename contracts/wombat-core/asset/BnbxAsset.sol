// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '../interfaces/IRelativePriceProvider.sol';
import './DynamicAsset.sol';

interface IStakeManager {
    function convertBnbToBnbX(uint256 _amount) external view returns (uint256);

    function convertBnbXToBnb(uint256 _amountInBnbX) external view returns (uint256);
}

/**
 * @title Asset with Dynamic Price
 * @notice Contract presenting an asset in a pool
 * @dev The relative price of an asset may change over time.
 * For example, the ratio of staked BNB : BNB increases as staking reward accrues.
 */
contract BnbxAsset is DynamicAsset {
    IStakeManager exchangeRateOracle;

    constructor(
        address underlyingToken_,
        string memory name_,
        string memory symbol_,
        IStakeManager _exchangeRateOracle
    ) DynamicAsset(underlyingToken_, name_, symbol_) {
        exchangeRateOracle = _exchangeRateOracle;
    }

    /**
     * @notice get the relative price in WAD
     */
    function getRelativePrice() external view override returns (uint256) {
        return exchangeRateOracle.convertBnbXToBnb(1e18);
    }
}
