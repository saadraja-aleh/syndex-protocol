// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IRewardEscrow {
    // Views
    function balanceOf(address account) external view returns (uint);

    function numVestingEntries(address account) external view returns (uint);

    function totalEscrowedAccountBalance(
        address account
    ) external view returns (uint);

    function totalVestedAccountBalance(
        address account
    ) external view returns (uint);

    function getVestingScheduleEntry(
        address account,
        uint index
    ) external view returns (uint[2] memory);

    function getNextVestingIndex(address account) external view returns (uint);

    // Mutative functions
    function appendVestingEntry(address account, uint quantity) external;

    function vest() external;
}
