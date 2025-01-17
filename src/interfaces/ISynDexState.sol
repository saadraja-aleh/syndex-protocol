// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ISynDexState {
    // Views
    function debtLedger(uint index) external view returns (uint);

    function issuanceData(
        address account
    ) external view returns (uint initialDebtOwnership, uint debtEntryIndex);

    function debtLedgerLength() external view returns (uint);

    function hasIssued(address account) external view returns (bool);

    function lastDebtLedgerEntry() external view returns (uint);

    // Mutative functions
    function incrementTotalIssuerCount() external;

    function decrementTotalIssuerCount() external;

    function setCurrentIssuanceData(
        address account,
        uint initialDebtOwnership
    ) external;

    function appendDebtLedgerValue(uint value) external;

    function clearIssuanceData(address account) external;
}
