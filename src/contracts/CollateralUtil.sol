// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./MixinSystemSettings.sol";

import "../interfaces/IExchangeRates.sol";
import "../interfaces/ICollateralLoan.sol";

import "../libraries/SafeDecimalMath.sol";

contract CollateralUtil is ICollateralLoan, MixinSystemSettings {
    /* ========== LIBRARIES ========== */
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== CONSTANTS ========== */

    bytes32 private constant cfUSD = "cfUSD";

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";

    function resolverAddressesRequired()
        public
        view
        override
        returns (bytes32[] memory addresses)
    {
        bytes32[] memory existingAddresses = MixinSystemSettings
            .resolverAddressesRequired();
        bytes32[] memory newAddresses = new bytes32[](1);
        newAddresses[0] = CONTRACT_EXRATES;
        addresses = combineArrays(existingAddresses, newAddresses);
    }

    /* ---------- Related Contracts ---------- */

    function _exchangeRates() internal view returns (IExchangeRates) {
        return
            IExchangeRates(
                resolver.requireAndGetAddress(
                    CONTRACT_EXRATES,
                    "Missing ExchangeRates contract"
                )
            );
    }

    constructor(address _resolver) MixinSystemSettings(_resolver) {}

    /* ========== UTILITY VIEW FUNCS ========== */

    function getCollateralRatio(
        Loan calldata loan,
        bytes32 collateralKey
    ) external view returns (uint cratio) {
        uint cvalue = _exchangeRates().effectiveValue(
            collateralKey,
            loan.collateral,
            cfUSD
        );
        uint dvalue = _exchangeRates().effectiveValue(
            loan.currency,
            loan.amount.add(loan.accruedInterest),
            cfUSD
        );
        return cvalue.divideDecimal(dvalue);
    }

    function maxLoan(
        uint amount,
        bytes32 currency,
        uint minCratio,
        bytes32 collateralKey
    ) external view returns (uint max) {
        uint ratio = SafeDecimalMath.unit().divideDecimalRound(minCratio);
        return
            ratio.multiplyDecimal(
                _exchangeRates().effectiveValue(collateralKey, amount, currency)
            );
    }

    /**
     * r = currentTarget issuance ratio
     * D = debt value in cfUSD
     * V = collateral value in cfUSD
     * P = liquidation penalty
     * Calculates amount of synths = (D - V * r) / (1 - (1 + P) * r)
     * Note: if you pass a loan in here that is not eligible for liquidation it will revert.
     * We check the ratio first in liquidateInternal and only pass eligible loans in.
     */
    function liquidationAmount(
        Loan calldata loan,
        uint minCratio,
        bytes32 collateralKey
    ) external view returns (uint amount) {
        uint liquidationPenalty = getLiquidationPenalty();
        uint debtValue = _exchangeRates().effectiveValue(
            loan.currency,
            loan.amount.add(loan.accruedInterest),
            cfUSD
        );
        uint collateralValue = _exchangeRates().effectiveValue(
            collateralKey,
            loan.collateral,
            cfUSD
        );
        uint unit = SafeDecimalMath.unit();

        uint dividend = debtValue.sub(collateralValue.divideDecimal(minCratio));
        uint divisor = unit.sub(
            unit.add(liquidationPenalty).divideDecimal(minCratio)
        );

        uint cfUSDamount = dividend.divideDecimal(divisor);

        return _exchangeRates().effectiveValue(cfUSD, cfUSDamount, loan.currency);
    }

    function collateralRedeemed(
        bytes32 currency,
        uint amount,
        bytes32 collateralKey
    ) external view returns (uint collateral) {
        uint liquidationPenalty = getLiquidationPenalty();
        collateral = _exchangeRates().effectiveValue(
            currency,
            amount,
            collateralKey
        );
        return
            collateral.multiplyDecimal(
                SafeDecimalMath.unit().add(liquidationPenalty)
            );
    }
}
