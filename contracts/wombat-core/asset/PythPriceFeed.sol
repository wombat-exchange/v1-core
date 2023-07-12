// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '@pythnetwork/pyth-sdk-solidity/IPyth.sol';
import '@pythnetwork/pyth-sdk-solidity/PythStructs.sol';

import './OraclePriceFeed.sol';

/**
 * @title Pyth Price Feed with fallback
 * @notice Contract to get the latest prices for multiple tokens from Pyth
 */
contract PythPriceFeed is OraclePriceFeed {
    IPyth pyth;
    mapping(IERC20 => bytes32) public priceIDs;
    mapping(IERC20 => uint256) public maxPriceAge;

    event UpdatepriceID(IERC20 token, bytes32 priceID, uint256 maxPriceAge);

    constructor(IPyth _pyth, uint256 _maxPriceAgeBound) OraclePriceFeed(_maxPriceAgeBound) {
        pyth = _pyth;
    }

    /**
     * Returns the latest price.
     */
    function getLatestPrice(IERC20 _token) external view returns (uint256 price) {
        bytes32 priceID = priceIDs[_token];
        PythStructs.Price memory priceStruct = pyth.getPrice(priceID);

        // If the price is too old, use the fallback price feed
        if (block.timestamp - priceStruct.publishTime > maxPriceAge[_token]) {
            return _getFallbackPrice(_token);
        } else {
            require(priceStruct.price > 0);
            return uint256(int256(priceStruct.price)) * (10 ** uint256(int256(priceStruct.expo + 18))); // upcast from `int64` and `int32`
        }
    }

    function setPriceID(IERC20 _token, bytes32 _priceID, uint256 _maxPriceAge) external onlyOwner {
        require(_maxPriceAge <= maxPriceAgeBound, 'invalid _maxPriceAge');
        priceIDs[_token] = _priceID;
        maxPriceAge[_token] = _maxPriceAge;
        emit UpdatepriceID(_token, _priceID, _maxPriceAge);
    }
}
