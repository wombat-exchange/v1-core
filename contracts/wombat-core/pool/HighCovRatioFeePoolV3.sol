// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.5;

import '../libraries/DSMath.sol';
import './PoolV3.sol';

/**
 * @title HighCovRatioFeePoolV3
 * @dev Pool with high cov ratio fee protection
 * Change log:
 * - V2: Add `gap` to prevent storage collision for future upgrades
 * - V3: Contract size compression
 */
contract HighCovRatioFeePoolV3 is PoolV3 {
    using DSMath for uint256;
    using SignedSafeMath for uint256;

    uint128 public startCovRatio; // 1.5
    uint128 public endCovRatio; // 1.8

    uint256[50] private gap;

    error WOMBAT_COV_RATIO_LIMIT_EXCEEDED();

    function initialize(uint256 ampFactor_, uint256 haircutRate_) public virtual override {
        super.initialize(ampFactor_, haircutRate_);
        startCovRatio = 15e17;
        endCovRatio = 18e17;
    }

    function setCovRatioFeeParam(uint128 startCovRatio_, uint128 endCovRatio_) external onlyOwner {
        if (startCovRatio_ < 1e18 || startCovRatio_ > endCovRatio_) revert WOMBAT_INVALID_VALUE();

        startCovRatio = startCovRatio_;
        endCovRatio = endCovRatio_;
    }

    /**
     * @dev Exact output swap (fromAmount < 0) should be only used by off-chain quoting function as it is a gas monster
     */
    function _quoteFrom(
        IAsset fromAsset,
        IAsset toAsset,
        int256 fromAmount
    ) internal view override returns (uint256 actualToAmount, uint256 haircut) {
        (actualToAmount, haircut) = super._quoteFrom(fromAsset, toAsset, fromAmount);

        if (fromAmount >= 0) {
            uint256 highCovRatioFee = CoreV3.highCovRatioFee(
                fromAsset.cash(),
                fromAsset.liability(),
                uint256(fromAmount),
                actualToAmount,
                startCovRatio,
                endCovRatio
            );

            actualToAmount -= highCovRatioFee;
            haircut += highCovRatioFee;
        } else {
            // reverse quote
            uint256 toAssetCash = toAsset.cash();
            uint256 toAssetLiability = toAsset.liability();
            uint256 finalToAssetCovRatio = (toAssetCash + actualToAmount).wdiv(toAssetLiability);
            if (finalToAssetCovRatio <= startCovRatio) {
                // happy path: no high cov ratio fee is charged
                return (actualToAmount, haircut);
            } else if (toAssetCash.wdiv(toAssetLiability) >= endCovRatio) {
                // the to-asset exceeds it's cov ratio limit, further swap to increase cov ratio is impossible
                revert WOMBAT_COV_RATIO_LIMIT_EXCEEDED();
            }

            // reverse quote: cov ratio of the to-asset exceed endCovRatio. direct reverse quote is not supported
            // we binary search for a upper bound
            actualToAmount = _findUpperBound(toAsset, fromAsset, uint256(-fromAmount));
            (, haircut) = _quoteFrom(toAsset, fromAsset, actualToAmount.toInt256());
        }
    }

    /**
     * @notice Binary search to find the upper bound of `fromAmount` required to swap `fromAsset` to `toAmount` of `toAsset`
     * @dev This function should only used as off-chain view function as it is a gas monster
     */
    function _findUpperBound(
        IAsset fromAsset,
        IAsset toAsset,
        uint256 toAmount
    ) internal view returns (uint256 upperBound) {
        uint8 decimals = fromAsset.underlyingTokenDecimals();
        uint256 toWadFactor = DSMath.toWad(1, decimals);
        // the search value uses the same number of digits as the token
        uint256 high = (uint256(fromAsset.liability()).wmul(endCovRatio) - fromAsset.cash()).fromWad(decimals);
        uint256 low = 1;

        // verify `high` is a valid upper bound
        uint256 quote;
        (quote, ) = _quoteFrom(fromAsset, toAsset, (high * toWadFactor).toInt256());
        if (quote < toAmount) revert WOMBAT_COV_RATIO_LIMIT_EXCEEDED();

        // Note: we might limit the maximum number of rounds if the request is always rejected by the RPC server
        while (low < high) {
            uint256 mid = (low + high) / 2;
            (quote, ) = _quoteFrom(fromAsset, toAsset, (mid * toWadFactor).toInt256());
            if (quote >= toAmount) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return high * toWadFactor;
    }

    /**
     * @dev take into account high cov ratio fee
     */
    function quotePotentialWithdrawFromOtherAsset(
        address fromToken,
        address toToken,
        uint256 liquidity
    ) external view virtual override returns (uint256 finalAmount, uint256 withdrewAmount) {
        _checkLiquidity(liquidity);
        _checkSameAddress(fromToken, toToken);

        IAsset fromAsset = _assetOf(fromToken);
        IAsset toAsset = _assetOf(toToken);
        uint256 scaleFactor = _quoteFactor(fromAsset, toAsset);
        (finalAmount, withdrewAmount) = CoreV3.quoteWithdrawAmountFromOtherAsset(
            fromAsset,
            toAsset,
            liquidity,
            ampFactor,
            scaleFactor,
            haircutRate,
            startCovRatio,
            endCovRatio,
            _getGlobalEquilCovRatioForDepositWithdrawal(),
            withdrawalHaircutRate
        );

        withdrewAmount = withdrewAmount.fromWad(fromAsset.underlyingTokenDecimals());
        finalAmount = finalAmount.fromWad(toAsset.underlyingTokenDecimals());
    }
}
