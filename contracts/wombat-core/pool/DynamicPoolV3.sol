// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import '../libraries/DSMath.sol';
import '../interfaces/IRelativePriceProvider.sol';
import './HighCovRatioFeePoolV3.sol';

/**
 * @title Dynamic Pool V3
 * @notice Manages deposits, withdrawals and swaps. Holds a mapping of assets and parameters.
 * @dev Supports dynamic assets. Assume r* to be close to 1.
 * Be aware that r* changes when the relative price of the asset updates
 * Change log:
 * - V2: add `gap` to prevent storage collision for future upgrades
 * - V2: Inherite from `HighCovRatioFeePoolV2` instead of `Pool`
 */
contract DynamicPoolV3 is HighCovRatioFeePoolV3 {
    using DSMath for uint256;
    using SignedSafeMath for int256;
    using SignedSafeMath for uint256;

    uint256[50] private gap;

    /**
     * @notice multiply / divide the cash, liability and amount of a swap by relative price
     * Invariant: D = Sum of P_i * L_i * (r_i - A / r_i)
     */
    function _quoteFactor(IAsset fromAsset, IAsset toAsset) internal view override returns (uint256) {
        uint256 fromAssetRelativePrice = IRelativePriceProvider(address(fromAsset)).getRelativePrice();
        // theoretically we should multiply toCash, toLiability and idealToAmount by toAssetRelativePrice
        // however we simplify the calculation by dividing "from amounts" by toAssetRelativePrice
        uint256 toAssetRelativePrice = IRelativePriceProvider(address(toAsset)).getRelativePrice();

        return (1e18 * fromAssetRelativePrice) / toAssetRelativePrice;
    }

    /**
     * @dev Invariant: D = Sum of P_i * L_i * (r_i - A / r_i)
     */
    function _globalInvariantFunc() internal view override returns (int256 D, int256 SL) {
        int256 A = ampFactor.toInt256();

        for (uint256 i; i < _sizeOfAssetList(); ++i) {
            IAsset asset = _getAsset(_getKeyAtIndex(i));

            // overflow is unrealistic
            int256 A_i = int256(uint256(asset.cash()));
            int256 L_i = int256(uint256(asset.liability()));
            int256 P_i = IRelativePriceProvider(address(asset)).getRelativePrice().toInt256();

            // Assume when L_i == 0, A_i always == 0
            if (L_i == 0) {
                // avoid division of 0
                continue;
            }

            int256 r_i = A_i.wdiv(L_i);
            SL += P_i.wmul(L_i);
            D += P_i.wmul(L_i).wmul(r_i - A.wdiv(r_i));
        }
    }
}
