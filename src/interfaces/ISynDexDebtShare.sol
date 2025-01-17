// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ISynDexDebtShare {
    // Views

    function currentPeriodId() external view returns (uint128);

    function allowance(
        address account,
        address spender
    ) external view returns (uint);

    function balanceOf(address account) external view returns (uint);

    function balanceOfOnPeriod(
        address account,
        uint periodId
    ) external view returns (uint);

    function totalSupply() external view returns (uint);

    function sharePercent(address account) external view returns (uint);

    function sharePercentOnPeriod(
        address account,
        uint periodId
    ) external view returns (uint);

    // Mutative functions

    function takeSnapshot(uint128 id) external;

    function mintShare(address account, uint256 amount) external;

    function burnShare(address account, uint256 amount) external;

    function approve(address, uint256) external pure returns (bool);

    function transfer(address to, uint256 amount) external pure returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function addAuthorizedBroker(address currentTarget) external;

    function removeAuthorizedBroker(address currentTarget) external;

    function addAuthorizedToSnapshot(address currentTarget) external;

    function removeAuthorizedToSnapshot(address currentTarget) external;
}
