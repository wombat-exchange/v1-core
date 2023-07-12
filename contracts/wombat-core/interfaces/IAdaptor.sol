// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.5;

interface IAdaptor {
    /* Cross-chain functions that is used to initiate a cross-chain message, should be invoked by Pool */

    function bridgeCreditAndSwapForTokens(
        address toToken,
        uint256 toChain,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address receiver,
        uint32 nonce
    ) external payable returns (uint256 trackingId);
}
