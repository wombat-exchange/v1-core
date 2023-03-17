// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.5;

interface IWhitelist {
    function approveWallet(address _wallet) external;

    function revokeWallet(address _wallet) external;

    function check(address _wallet) external view returns (bool);
}
