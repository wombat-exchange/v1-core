// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.15;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './IBribe.sol';

interface IVoter {
    struct GaugeWeight {
        uint128 allocPoint;
        uint128 voteWeight; // total amount of votes for an LP-token
    }

    // lpToken => weight, equals to sum of votes for a LP token
    function weights(address _lpToken) external view returns (GaugeWeight memory);

    // user address => lpToken => votes
    function votes(address _user, address _lpToken) external view returns (uint256);

    function setBribe(IERC20 _lpToken, IBribe _bribe) external;

    function distribute(address _lpToken) external;
}
