// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IDepot {
    // Views
    function fundsWallet() external view returns (address payable);

    function maxEthPurchase() external view returns (uint);

    function minimumDepositAmount() external view returns (uint);

    function synthsReceivedForEther(uint amount) external view returns (uint);

    function totalSellableDeposits() external view returns (uint);

    // Mutative functions
    function depositSynths(uint amount) external;

    function exchangeEtherForSynths() external payable returns (uint);

    function exchangeEtherForSynthsAtRate(
        uint guaranteedRate
    ) external payable returns (uint);

    function withdrawMyDepositedSynths() external;

    // Note: On mainnet no SFCX has been deposited. The following functions are kept alive for testnet SFCX faucets.
    function exchangeEtherForSFCX() external payable returns (uint);

    function exchangeEtherForSFCXAtRate(
        uint guaranteedRate,
        uint guaranteedSynDexRate
    ) external payable returns (uint);

    function exchangeSynthsForSFCX(uint synthAmount) external returns (uint);

    function syndexReceivedForEther(
        uint amount
    ) external view returns (uint);

    function syndexReceivedForSynths(
        uint amount
    ) external view returns (uint);

    function withdrawSynDex(uint amount) external;
}
