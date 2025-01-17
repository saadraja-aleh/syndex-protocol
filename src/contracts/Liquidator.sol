// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./MixinSystemSettings.sol";

import "../interfaces/IERC20.sol";
import "../interfaces/IIssuer.sol";
import "../interfaces/ISynDex.sol";
import "../interfaces/ILiquidator.sol";
import "../interfaces/IHasBalance.sol";
import "../interfaces/ISystemStatus.sol";
import "../interfaces/IExchangeRates.sol";
import "../interfaces/IFlexibleStorage.sol";

import "../libraries/SafeDecimalMath.sol";

/// @title Upgrade Liquidation Mechanism V2 (SIP-148)
/// @notice This contract is a modification to the existing liquidation mechanism defined in SIP-15
contract Liquidator is Ownable, MixinSystemSettings, ILiquidator {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    struct LiquidationEntry {
        uint deadline;
        address caller;
    }

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_SYSTEMSTATUS = "SystemStatus";
    bytes32 private constant CONTRACT_SYNDEX = "SynDex";
    bytes32 private constant CONTRACT_ISSUER = "Issuer";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_SYNDEXESCROW = "SynDexEscrow";
    bytes32 private constant CONTRACT_V3_LEGACYMARKET = "LegacyMarket";

    /* ========== CONSTANTS ========== */

    bytes32 public constant CONTRACT_NAME = "Liquidator";

    // Storage keys
    bytes32 public constant LIQUIDATION_DEADLINE = "LiquidationDeadline";
    bytes32 public constant LIQUIDATION_CALLER = "LiquidationCaller";

    constructor(
        address _owner,
        address _resolver
    ) Ownable(_owner) MixinSystemSettings(_resolver) {}

    /* ========== VIEWS ========== */
    function resolverAddressesRequired()
        public
        view
        override
        returns (bytes32[] memory addresses)
    {
        bytes32[] memory existingAddresses = MixinSystemSettings
            .resolverAddressesRequired();
        bytes32[] memory newAddresses = new bytes32[](4);
        newAddresses[0] = CONTRACT_SYSTEMSTATUS;
        newAddresses[1] = CONTRACT_SYNDEX;
        newAddresses[2] = CONTRACT_ISSUER;
        newAddresses[3] = CONTRACT_EXRATES;
        addresses = combineArrays(existingAddresses, newAddresses);
    }

    function syndex() internal view returns (ISynDex) {
        return ISynDex(requireAndGetAddress(CONTRACT_SYNDEX));
    }

    function systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(requireAndGetAddress(CONTRACT_SYSTEMSTATUS));
    }

    function issuer() internal view returns (IIssuer) {
        return IIssuer(requireAndGetAddress(CONTRACT_ISSUER));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES));
    }

    function issuanceRatio() external view returns (uint) {
        return getIssuanceRatio();
    }

    function liquidationDelay() external view returns (uint) {
        return getLiquidationDelay();
    }

    function liquidationRatio() external view returns (uint) {
        return getLiquidationRatio();
    }

    function liquidationEscrowDuration() external view returns (uint) {
        return getLiquidationEscrowDuration();
    }

    function liquidationPenalty() external view returns (uint) {
        // SIP-251: use getSfcxLiquidationPenalty instead of getLiquidationPenalty
        // which is used for loans / shorts (collateral contracts).
        // Keeping the view name because it makes sense in the context of this contract.
        return getSfcxLiquidationPenalty();
    }

    function selfLiquidationPenalty() external view returns (uint) {
        return getSelfLiquidationPenalty();
    }

    function liquidateReward() external view returns (uint) {
        return getLiquidateReward();
    }

    function flagReward() external view returns (uint) {
        return getFlagReward();
    }

    function liquidationCollateralRatio() external view returns (uint) {
        return SafeDecimalMath.unit().divideDecimalRound(getLiquidationRatio());
    }

    function getLiquidationDeadlineForAccount(
        address account
    ) external view returns (uint) {
        LiquidationEntry memory liquidation = _getLiquidationEntryForAccount(
            account
        );
        return liquidation.deadline;
    }

    function getLiquidationCallerForAccount(
        address account
    ) external view returns (address) {
        LiquidationEntry memory liquidation = _getLiquidationEntryForAccount(
            account
        );
        return liquidation.caller;
    }

    /// @notice Determines if an account is eligible for forced or self liquidation
    /// @dev An account is eligible to self liquidate if its c-ratio is below the currentTarget c-ratio
    /// @dev An account with no SFCX collateral will not be open for liquidation since the ratio is 0
    function isLiquidationOpen(
        address account,
        bool isSelfLiquidation
    ) external view returns (bool) {
        uint accountCollateralisationRatio = syndex().collateralisationRatio(
            account
        );

        // Not open for liquidation if collateral ratio is less than or equal to currentTarget issuance ratio
        if (accountCollateralisationRatio <= getIssuanceRatio()) {
            return false;
        }

        if (!isSelfLiquidation) {
            LiquidationEntry
                memory liquidation = _getLiquidationEntryForAccount(account);

            // Open for liquidation if the deadline has passed and the user has enough SFCX collateral.
            if (
                _deadlinePassed(liquidation.deadline) &&
                _hasEnoughSFCXForRewards(account)
            ) {
                return true;
            }
            return false;
        } else {
            // Not open for self-liquidation when the account's collateral value is less than debt issued + forced penalty
            uint unit = SafeDecimalMath.unit();
            if (
                accountCollateralisationRatio >
                (unit.divideDecimal(unit.add(getSfcxLiquidationPenalty())))
            ) {
                return false;
            }
        }
        return true;
    }

    /// View for calculating the amounts of collateral (liquid and escrow that will be liquidated), and debt that will
    /// be removed.
    /// @param account The account to be liquidated
    /// @param isSelfLiquidation boolean to determine if this is a forced or self-invoked liquidation
    /// @return totalRedeemed the total amount of collateral (SFCX) to redeem (liquid and escrow)
    /// @return debtToRemove the amount of debt (cfUSD) to burn in order to fix the account's c-ratio
    /// @return escrowToLiquidate the amount of escrow SFCX that will be revoked during liquidation
    /// @return initialDebtBalance the amount of initial (cfUSD) debt the account has
    function liquidationAmounts(
        address account,
        bool isSelfLiquidation
    )
        external
        view
        returns (
            uint totalRedeemed,
            uint debtToRemove,
            uint escrowToLiquidate,
            uint initialDebtBalance
        )
    {
        // return zeroes otherwise calculateAmountToFixCollateral reverts with unhelpful underflow error
        if (!this.isLiquidationOpen(account, isSelfLiquidation)) {
            return (0, 0, 0, issuer().debtBalanceOf(account, "cfUSD"));
        }

        return issuer().liquidationAmounts(account, isSelfLiquidation);
    }

    function isLiquidationDeadlinePassed(
        address account
    ) external view returns (bool) {
        LiquidationEntry memory liquidation = _getLiquidationEntryForAccount(
            account
        );
        return _deadlinePassed(liquidation.deadline);
    }

    function _deadlinePassed(uint deadline) internal view returns (bool) {
        // check deadline is set > 0
        // check block.timestamp > deadline
        return deadline > 0 && block.timestamp > deadline;
    }

    /// @notice Checks if an account has enough SFCX balance to be considered open for forced liquidation.
    function _hasEnoughSFCXForRewards(
        address account
    ) internal view returns (bool) {
        uint balance = issuer().collateral(account);
        return balance >= (getLiquidateReward().add(getFlagReward()));
    }

    /**
     * r = currentTarget issuance ratio
     * D = debt value
     * V = collateral value
     * P = liquidation penalty
     * S = debt amount to redeem
     * Calculates amount of synths = (D - V * r) / (1 - (1 + P) * r)
     *
     * Derivation of the formula:
     *   Collateral "sold" with penalty: collateral-sold = S * (1 + P)
     *   After liquidation: new-debt = D - S, new-collateral = V - collateral-sold = V - S * (1 + P)
     *   Because we fixed the c-ratio, new-debt / new-collateral = c-ratio: (D - S) / (V - S * (1 + P)) = r
     *   After solving for S we get: S = (D - V * r) / (1 - (1 + P) * r)
     * Note: this only returns the amount of debt to remove "assuming the penalty", the penalty still needs to be
     * correctly applied when removing collateral.
     */
    function calculateAmountToFixCollateral(
        uint debtBalance,
        uint collateral,
        uint penalty
    ) external view returns (uint) {
        uint ratio = getIssuanceRatio();
        uint unit = SafeDecimalMath.unit();

        uint dividend = debtBalance.sub(collateral.multiplyDecimal(ratio));
        uint divisor = unit.sub(unit.add(penalty).multiplyDecimal(ratio));

        return dividend.divideDecimal(divisor);
    }

    // get liquidationEntry for account
    // returns deadline = 0 when not set
    function _getLiquidationEntryForAccount(
        address account
    ) internal view returns (LiquidationEntry memory _liquidation) {
        _liquidation.deadline = flexibleStorage().getUIntValue(
            CONTRACT_NAME,
            _getKey(LIQUIDATION_DEADLINE, account)
        );

        // This is used to reward the caller for flagging an account for liquidation.
        _liquidation.caller = flexibleStorage().getAddressValue(
            CONTRACT_NAME,
            _getKey(LIQUIDATION_CALLER, account)
        );
    }

    function _getKey(
        bytes32 _scope,
        address _account
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_scope, _account));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // totalIssuedSynths checks synths for staleness
    // check sfcx rate is not stale
    function flagAccountForLiquidation(
        address account
    ) external rateNotInvalid("SFCX") {
        systemStatus().requireSystemActive();

        require(
            resolver.getAddress(CONTRACT_V3_LEGACYMARKET) == address(0),
            "Must liquidate using V3"
        );

        require(getLiquidationRatio() > 0, "Liquidation ratio not set");
        require(getLiquidationDelay() > 0, "Liquidation delay not set");

        LiquidationEntry memory liquidation = _getLiquidationEntryForAccount(
            account
        );
        require(
            liquidation.deadline == 0,
            "Account already flagged for liquidation"
        );

        uint accountsCollateralisationRatio = syndex()
            .collateralisationRatio(account);

        // if accounts issuance ratio is greater than or equal to liquidation ratio set liquidation entry
        require(
            accountsCollateralisationRatio >= getLiquidationRatio(),
            "Account issuance ratio is less than liquidation ratio"
        );

        // if account doesn't have enough liquidatable collateral for rewards the liquidation transaction
        // is not possible
        require(_hasEnoughSFCXForRewards(account), "not enough SFCX for rewards");

        uint deadline = block.timestamp.add(getLiquidationDelay());

        _storeLiquidationEntry(account, deadline, msg.sender);

        emit AccountFlaggedForLiquidation(account, deadline);
    }

    /// @notice This function is called by the Issuer to remove an account's liquidation entry
    /// @dev The Issuer must check if the account's c-ratio is fixed before removing
    function removeAccountInLiquidation(address account) external onlyIssuer {
        LiquidationEntry memory liquidation = _getLiquidationEntryForAccount(
            account
        );
        if (liquidation.deadline > 0) {
            _removeLiquidationEntry(account);
        }
    }

    /// @notice External function to allow anyone to remove an account's liquidation entry
    /// @dev This function checks if the account's c-ratio is OK and that the rate of SFCX is not stale
    function checkAndRemoveAccountInLiquidation(
        address account
    ) external rateNotInvalid("SFCX") {
        systemStatus().requireSystemActive();

        LiquidationEntry memory liquidation = _getLiquidationEntryForAccount(
            account
        );

        require(liquidation.deadline > 0, "Account has no liquidation set");

        uint accountsCollateralisationRatio = syndex()
            .collateralisationRatio(account);

        // Remove from liquidator if accountsCollateralisationRatio is fixed (less than equal currentTarget issuance ratio)
        if (accountsCollateralisationRatio <= getIssuanceRatio()) {
            _removeLiquidationEntry(account);
        }
    }

    function _storeLiquidationEntry(
        address _account,
        uint _deadline,
        address _caller
    ) internal {
        // record liquidation deadline and caller
        flexibleStorage().setUIntValue(
            CONTRACT_NAME,
            _getKey(LIQUIDATION_DEADLINE, _account),
            _deadline
        );

        flexibleStorage().setAddressValue(
            CONTRACT_NAME,
            _getKey(LIQUIDATION_CALLER, _account),
            _caller
        );
    }

    /// @notice Only delete the deadline value, keep caller for flag reward payout
    function _removeLiquidationEntry(address _account) internal {
        flexibleStorage().deleteUIntValue(
            CONTRACT_NAME,
            _getKey(LIQUIDATION_DEADLINE, _account)
        );

        emit AccountRemovedFromLiquidation(_account, block.timestamp);
    }

    /* ========== MODIFIERS ========== */
    modifier onlyIssuer() {
        require(
            msg.sender == address(issuer()),
            "Liquidator: Only the Issuer contract can perform this action"
        );
        _;
    }

    modifier rateNotInvalid(bytes32 currencyKey) {
        require(
            !exchangeRates().rateIsInvalid(currencyKey),
            "Rate invalid or not a synth"
        );
        _;
    }

    /* ========== EVENTS ========== */

    event AccountFlaggedForLiquidation(address indexed account, uint deadline);
    event AccountRemovedFromLiquidation(address indexed account, uint time);
}
