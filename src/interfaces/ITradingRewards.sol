// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ITradingRewards {
    /* ========== VIEWS ========== */

    function getAvailableRewards() external view returns (uint);

    function getUnassignedRewards() external view returns (uint);

    function getRewardsToken() external view returns (address);

    function getPeriodController() external view returns (address);

    function getCurrentPeriod() external view returns (uint);

    function isPeriodClaimable(uint periodID) external view returns (bool);

    function getPeriodIsFinalized(uint periodID) external view returns (bool);

    function getPeriodRecordedFees(uint periodID) external view returns (uint);

    function getPeriodTotalRewards(uint periodID) external view returns (uint);

    function getPeriodAvailableRewards(
        uint periodID
    ) external view returns (uint);

    function getUnaccountedFeesForAccountForPeriod(
        address account,
        uint periodID
    ) external view returns (uint);

    function getAvailableRewardsForAccountForPeriod(
        address account,
        uint periodID
    ) external view returns (uint);

    function getAvailableRewardsForAccountForPeriods(
        address account,
        uint[] calldata periodIDs
    ) external view returns (uint totalRewards);

    /* ========== MUTATIVE FUNCTIONS ========== */

    function redeemRewardsForPeriod(uint periodID) external;

    function claimRewardsForPeriods(uint[] calldata periodIDs) external;

    /* ========== RESTRICTED FUNCTIONS ========== */

    function recordExchangeFeeForAccount(
        uint usdFeeAmount,
        address account
    ) external;

    function closeCurrentPeriodWithRewards(uint rewards) external;

    function recoverTokens(
        address tokenAddress,
        address recoverAddress
    ) external;

    function recoverUnassignedRewardTokens(address recoverAddress) external;

    function recoverAssignedRewardTokensAndDestroyPeriod(
        address recoverAddress,
        uint periodID
    ) external;

    function setPeriodController(address newPeriodController) external;
}
