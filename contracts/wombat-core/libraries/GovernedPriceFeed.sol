// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.5;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/access/AccessControlEnumerable.sol';

import '../interfaces/IPriceFeed.sol';

/**
 * @notice Price feed managed by operator
 * @dev This contract is used as a temporary solution and should be migrated to use oracle when possible
 */
contract GovernedPriceFeed is IPriceFeed, Ownable, AccessControlEnumerable {
    bytes32 public constant ROLE_OPERATOR = keccak256('operator');

    IERC20 public immutable token;

    /// @notice max deviation allowed for updating oracle in case wrong parameter is supplied
    uint256 public immutable maxDeviation;

    uint256 public lastUpdate;

    uint256 private _price;

    event SetLatestPrice(uint256 newPrice);

    constructor(IERC20 _token, uint256 _initialPrice, uint256 _maxDeviation) {
        token = _token;
        _price = _initialPrice;
        maxDeviation = _maxDeviation;
        _grantRole(ROLE_OPERATOR, msg.sender); // owner is an operator
    }

    function addOperator(address _operator) external onlyOwner {
        _grantRole(ROLE_OPERATOR, _operator);
    }

    function removeOperator(address _operator) external onlyOwner {
        _revokeRole(ROLE_OPERATOR, _operator);
    }

    function setLatestPrice(uint256 _newPrice) external {
        require(hasRole(ROLE_OPERATOR, msg.sender), 'not authorized');
        if (_newPrice >= _price) {
            require(_newPrice - _price <= maxDeviation, 'maxDeviation not respected');
        } else {
            require(_price - _newPrice <= maxDeviation, 'maxDeviation not respected');
        }
        _price = _newPrice;
        lastUpdate = block.timestamp;

        emit SetLatestPrice(_newPrice);
    }

    /**
     * @notice return price of the asset in 18 decimals
     */
    function getLatestPrice(IERC20 _token) external view returns (uint256) {
        require(_token == token, 'unknown token');
        return _price;
    }
}
