// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.5;

interface IWom {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);

    /*///////////////////////////////////////////////////////////////
                            IERC20Metadata
    //////////////////////////////////////////////////////////////*/
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    /*///////////////////////////////////////////////////////////////
                            IERC20
    //////////////////////////////////////////////////////////////*/
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address receipient, uint256 amount) external returns (bool);

    function transferFrom(address sender, address receipient, uint256 amount) external returns (bool);

    /*///////////////////////////////////////////////////////////////
                            IERC20Permit
    //////////////////////////////////////////////////////////////*/
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
