// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.5;

interface ICrossChainPool {
    function swapTokensForTokensCrossChain(
        address fromToken,
        address toToken,
        uint256 toChain,
        uint256 fromAmount,
        uint256 minimumCreditAmount,
        uint256 minimumToAmount,
        address receiver,
        uint32 nonce
    ) external payable returns (uint256 creditAmount, uint256 haircut, uint256 id);

    function swapCreditForTokens(
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address receiver
    ) external returns (uint256 actualToAmount, uint256 haircut);

    function swapCreditForTokensCrossChain(
        address toToken,
        uint256 toChain,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address receiver,
        uint32 nonce
    ) external payable returns (uint256 id);

    /*
     * Permissioned Functions
     */

    function completeSwapCreditForTokens(
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address receiver,
        uint256 trackingId
    ) external returns (uint256 actualToAmount, uint256 haircut);

    function mintCredit(uint256 creditAmount, address receiver, uint256 trackingId) external;
}
