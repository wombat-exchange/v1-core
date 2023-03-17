// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

import '../interfaces/IPool.sol';
import '../interfaces/IWombatRouter.sol';

interface IWNative {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}

/**
 * @title WombatRouter
 * @notice Allows routing on different wombat pools
 * @dev Owner is allowed and required to approve token spending by pools via approveSpendingByPool function.
 * With great thanks to the uniswap team for your contribution to the opensource community
 * reference: https://github.com/Uniswap/v2-periphery/blob/master/contracts/UniswapV2Router02.sol
 */
contract WombatRouter is Ownable, IWombatRouter {
    using SafeERC20 for IERC20;

    // WBNB (mainnet): 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
    // WBNB (testnet): 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd
    IWNative public immutable wNative;

    constructor(IWNative _wNative) {
        wNative = _wNative;
    }

    receive() external payable {
        require(msg.sender == address(wNative));
    }

    /// @notice approve spending of router tokens by pool
    /// @param tokens array of tokens to be approved
    /// @param pool to be approved to spend
    /// @dev needs to be done after asset deployment for router to be able to support the tokens
    function approveSpendingByPool(address[] calldata tokens, address pool) external onlyOwner {
        for (uint256 i; i < tokens.length; ++i) {
            IERC20(tokens[i]).safeApprove(pool, 0);
            IERC20(tokens[i]).safeApprove(pool, type(uint256).max);
        }
    }

    function addLiquidityNative(
        IPool pool,
        uint256 minimumLiquidity,
        address to,
        uint256 deadline,
        bool shouldStake
    ) external payable override returns (uint256 liquidity) {
        wNative.deposit{value: msg.value}();
        return pool.deposit(address(wNative), msg.value, minimumLiquidity, to, deadline, shouldStake);
    }

    function removeLiquidityNative(
        IPool pool,
        uint256 liquidity,
        uint256 minimumAmount,
        address to,
        uint256 deadline
    ) external override returns (uint256 amount) {
        address asset = pool.addressOfAsset(address(wNative));
        IERC20(asset).transferFrom(address(msg.sender), address(this), liquidity);

        amount = pool.withdraw(address(wNative), liquidity, minimumAmount, address(this), deadline);
        wNative.withdraw(amount);
        _safeTransferNative(to, amount);
    }

    function removeLiquidityFromOtherAssetAsNative(
        IPool pool,
        address fromToken,
        uint256 liquidity,
        uint256 minimumAmount,
        address to,
        uint256 deadline
    ) external returns (uint256 amount) {
        address asset = pool.addressOfAsset(fromToken);
        IERC20(asset).transferFrom(address(msg.sender), address(this), liquidity);

        amount = pool.withdrawFromOtherAsset(
            fromToken,
            address(wNative),
            liquidity,
            minimumAmount,
            address(this),
            deadline
        );
        wNative.withdraw(amount);
        _safeTransferNative(to, amount);
    }

    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible, along the route determined by the path
    /// @param tokenPath An array of token addresses. path.length must be >= 2.
    /// @param tokenPath The first element of the path is the input token, the last element is the output token.
    /// @param poolPath An array of pool addresses. The pools where the pathTokens are contained in order.
    /// @param amountIn the amount in
    /// @param minimumamountOut the minimum amount to get for user
    /// @param to the user to send the tokens to
    /// @param deadline the deadline to respect
    /// @return amountOut received by user
    function swapExactTokensForTokens(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 amountIn,
        uint256 minimumamountOut,
        address to,
        uint256 deadline
    ) external override returns (uint256 amountOut) {
        require(deadline >= block.timestamp, 'expired');
        require(tokenPath.length >= 2, 'invalid token path');
        require(poolPath.length == tokenPath.length - 1, 'invalid pool path');

        // get from token from users
        IERC20(tokenPath[0]).safeTransferFrom(address(msg.sender), address(this), amountIn);

        amountOut = _swap(tokenPath, poolPath, amountIn, to);
        require(amountOut >= minimumamountOut, 'amountOut too low');
    }

    function swapExactNativeForTokens(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 minimumamountOut,
        address to,
        uint256 deadline
    ) external payable override returns (uint256 amountOut) {
        require(tokenPath[0] == address(wNative), 'the first address should be wrapped token');
        require(deadline >= block.timestamp, 'expired');
        require(poolPath.length == tokenPath.length - 1, 'invalid pool path');

        // get wrapped tokens
        wNative.deposit{value: msg.value}();

        amountOut = _swap(tokenPath, poolPath, msg.value, to);
        require(amountOut >= minimumamountOut, 'amountOut too low');
    }

    function swapExactTokensForNative(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 amountIn,
        uint256 minimumamountOut,
        address to,
        uint256 deadline
    ) external override returns (uint256 amountOut) {
        require(tokenPath[tokenPath.length - 1] == address(wNative), 'the last address should be wrapped token');
        require(deadline >= block.timestamp, 'expired');
        require(poolPath.length == tokenPath.length - 1, 'invalid pool path');

        // get from token from users
        IERC20(tokenPath[0]).safeTransferFrom(address(msg.sender), address(this), amountIn);

        amountOut = _swap(tokenPath, poolPath, amountIn, address(this));
        require(amountOut >= minimumamountOut, 'amountOut too low');

        wNative.withdraw(amountOut);
        _safeTransferNative(to, amountOut);
    }

    /// @notice Private function to swap alone the token path
    /// @dev Assumes router has initial amountIn in balance.
    /// Assumes tokens being swapped have been approve via the approveSpendingByPool function
    /// @param tokenPath An array of token addresses. path.length must be >= 2.
    /// @param tokenPath The first element of the path is the input token, the last element is the output token.
    /// @param poolPath An array of pool addresses. The pools where the pathTokens are contained in order.
    /// @param amountIn the amount in
    /// @param to the user to send the tokens to
    /// @return amountOut received by user
    function _swap(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 amountIn,
        address to
    ) internal returns (uint256 amountOut) {
        // next from amount, starts with amountIn in arg
        uint256 nextamountIn = amountIn;

        // first n - 1 swaps
        for (uint256 i; i < poolPath.length - 1; ++i) {
            // make the swap with the correct arguments
            (amountOut, ) = IPool(poolPath[i]).swap(
                tokenPath[i],
                tokenPath[i + 1],
                nextamountIn,
                0, // minimum amount received is ensured on calling function
                address(this),
                type(uint256).max // deadline is ensured on calling function
            );
            nextamountIn = amountOut;
        }

        // last swap
        uint256 i = poolPath.length - 1;
        (amountOut, ) = IPool(poolPath[i]).swap(
            tokenPath[i],
            tokenPath[i + 1],
            nextamountIn,
            0, // minimum amount received is ensured on calling function
            to,
            type(uint256).max // deadline is ensured on calling function
        );
    }

    /**
     * @notice Given an input asset amount and an array of token addresses, calculates the
     * maximum output token amount (accounting for fees and slippage).
     * @param tokenPath The token swap path
     * @param poolPath The token pool path
     * @param amountIn The from amount
     * @return amountOut The potential final amount user would receive
     */
    function getAmountOut(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        int256 amountIn
    ) external view override returns (uint256 amountOut, uint256[] memory haircuts) {
        require(tokenPath.length >= 2, 'invalid token path');
        require(poolPath.length == tokenPath.length - 1, 'invalid pool path');

        // next from amount, starts with amountIn in arg
        int256 nextamountIn = amountIn;
        haircuts = new uint256[](poolPath.length);

        for (uint256 i; i < poolPath.length; ++i) {
            // make the swap with the correct arguments
            (amountOut, haircuts[i]) = IPool(poolPath[i]).quotePotentialSwap(
                tokenPath[i],
                tokenPath[i + 1],
                nextamountIn
            );
            nextamountIn = int256(amountOut);
        }
    }

    /**
     * @notice Returns the minimum input asset amount required to buy the given output asset amount
     * (accounting for fees and slippage)
     * Note: This function should be used as estimation only. The actual swap amount might
     * be different due to precision error (the error is typically under 1e-6)
     * @param tokenPath The token swap path
     * @param poolPath The token pool path
     * @param amountOut The to amount
     * @return amountIn The potential final amount user would receive
     */
    function getAmountIn(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 amountOut
    ) external view override returns (uint256 amountIn, uint256[] memory haircuts) {
        require(tokenPath.length >= 2, 'invalid token path');
        require(poolPath.length == tokenPath.length - 1, 'invalid pool path');

        // next from amount, starts with amountIn in arg
        int256 nextAmountOut = int256(amountOut);
        haircuts = new uint256[](poolPath.length);

        for (uint256 i = poolPath.length; i > 0; --i) {
            (amountIn, haircuts[i - 1]) = IPool(poolPath[i - 1]).quoteAmountIn(
                tokenPath[i - 1],
                tokenPath[i],
                nextAmountOut
            );
            nextAmountOut = int256(amountIn);
        }
    }

    function _safeTransferNative(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, '_safeTransferNative fails');
    }
}
