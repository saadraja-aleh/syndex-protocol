// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./MixinResolver.sol";
import "./RewardsDistributionRecipient.sol";

import "../interfaces/IExchanger.sol";
import "../interfaces/ITradingRewards.sol";

import "../libraries/SafeDecimalMath.sol";

contract TradingRewards is
    ITradingRewards,
    ReentrancyGuard,
    Ownable,
    Pausable,
    MixinResolver,
    RewardsDistributionRecipient
{
    using SafeMath for uint;
    using SafeDecimalMath for uint;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    uint private _currentPeriodID;
    uint private _balanceAssignedToRewards;
    mapping(uint => Period) private _periods;

    struct Period {
        bool isFinalized;
        uint recordedFees;
        uint totalRewards;
        uint availableRewards;
        mapping(address => uint) unaccountedFeesForAccount;
    }

    address private _periodController;

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_EXCHANGER = "Exchanger";
    bytes32 private constant CONTRACT_SYNDEX = "ProxySFCX"; // ProxySFCX, SynDex

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address owner,
        address periodController,
        address resolver
    ) Ownable(owner) MixinResolver(resolver) {
        require(periodController != address(0), "Invalid period controller");

        _periodController = periodController;
    }

    /* ========== VIEWS ========== */

    function resolverAddressesRequired()
        public
        view
        override
        returns (bytes32[] memory addresses)
    {
        addresses = new bytes32[](2);
        addresses[0] = CONTRACT_EXCHANGER;
        addresses[1] = CONTRACT_SYNDEX;
    }

    function syndex() internal view returns (IERC20) {
        return IERC20(requireAndGetAddress(CONTRACT_SYNDEX));
    }

    function exchanger() internal view returns (IExchanger) {
        return IExchanger(requireAndGetAddress(CONTRACT_EXCHANGER));
    }

    function getAvailableRewards() external view returns (uint) {
        return _balanceAssignedToRewards;
    }

    function getUnassignedRewards() external view returns (uint) {
        return syndex().balanceOf(address(this)).sub(_balanceAssignedToRewards);
    }

    function getRewardsToken() external view returns (address) {
        return address(syndex());
    }

    function getPeriodController() external view returns (address) {
        return _periodController;
    }

    function getCurrentPeriod() external view returns (uint) {
        return _currentPeriodID;
    }

    function isPeriodClaimable(uint periodID) external view returns (bool) {
        return _periods[periodID].isFinalized;
    }

    function getPeriodIsFinalized(uint periodID) external view returns (bool) {
        return _periods[periodID].isFinalized;
    }

    function getPeriodRecordedFees(uint periodID) external view returns (uint) {
        return _periods[periodID].recordedFees;
    }

    function getPeriodTotalRewards(uint periodID) external view returns (uint) {
        return _periods[periodID].totalRewards;
    }

    function getPeriodAvailableRewards(
        uint periodID
    ) external view returns (uint) {
        return _periods[periodID].availableRewards;
    }

    function getUnaccountedFeesForAccountForPeriod(
        address account,
        uint periodID
    ) external view returns (uint) {
        return _periods[periodID].unaccountedFeesForAccount[account];
    }

    function getAvailableRewardsForAccountForPeriod(
        address account,
        uint periodID
    ) external view returns (uint) {
        return _calculateRewards(account, periodID);
    }

    function getAvailableRewardsForAccountForPeriods(
        address account,
        uint[] calldata periodIDs
    ) external view returns (uint totalRewards) {
        for (uint i = 0; i < periodIDs.length; i++) {
            uint periodID = periodIDs[i];

            totalRewards = totalRewards.add(
                _calculateRewards(account, periodID)
            );
        }
    }

    function _calculateRewards(
        address account,
        uint periodID
    ) internal view returns (uint) {
        Period storage period = _periods[periodID];
        if (
            period.availableRewards == 0 ||
            period.recordedFees == 0 ||
            !period.isFinalized
        ) {
            return 0;
        }

        uint accountFees = period.unaccountedFeesForAccount[account];
        if (accountFees == 0) {
            return 0;
        }

        uint participationRatio = accountFees.divideDecimal(
            period.recordedFees
        );
        return participationRatio.multiplyDecimal(period.totalRewards);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function redeemRewardsForPeriod(
        uint periodID
    ) external nonReentrant whenNotPaused {
        _claimRewards(msg.sender, periodID);
    }

    function claimRewardsForPeriods(
        uint[] calldata periodIDs
    ) external nonReentrant whenNotPaused {
        for (uint i = 0; i < periodIDs.length; i++) {
            uint periodID = periodIDs[i];

            // Will revert if any independent claim reverts.
            _claimRewards(msg.sender, periodID);
        }
    }

    function _claimRewards(address account, uint periodID) internal {
        Period storage period = _periods[periodID];
        require(period.isFinalized, "Period is not finalized");

        uint amountToClaim = _calculateRewards(account, periodID);
        require(amountToClaim > 0, "No rewards available");

        period.unaccountedFeesForAccount[account] = 0;
        period.availableRewards = period.availableRewards.sub(amountToClaim);

        _balanceAssignedToRewards = _balanceAssignedToRewards.sub(
            amountToClaim
        );

        syndex().safeTransfer(account, amountToClaim);

        emit RewardsClaimed(account, amountToClaim, periodID);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function recordExchangeFeeForAccount(
        uint usdFeeAmount,
        address account
    ) external onlyExchanger {
        Period storage period = _periods[_currentPeriodID];
        // Note: In theory, the current period will never be finalized.
        // Such a require could be added here, but it would just spend gas, since it should always satisfied.

        period.unaccountedFeesForAccount[account] = period
            .unaccountedFeesForAccount[account]
            .add(usdFeeAmount);
        period.recordedFees = period.recordedFees.add(usdFeeAmount);

        emit ExchangeFeeRecorded(account, usdFeeAmount, _currentPeriodID);
    }

    function closeCurrentPeriodWithRewards(
        uint rewards
    ) external onlyPeriodController {
        uint currentBalance = syndex().balanceOf(address(this));
        uint availableForNewRewards = currentBalance.sub(
            _balanceAssignedToRewards
        );
        require(rewards <= availableForNewRewards, "Insufficient free rewards");

        Period storage period = _periods[_currentPeriodID];

        period.totalRewards = rewards;
        period.availableRewards = rewards;
        period.isFinalized = true;

        _balanceAssignedToRewards = _balanceAssignedToRewards.add(rewards);

        emit PeriodFinalizedWithRewards(_currentPeriodID, rewards);

        _currentPeriodID = _currentPeriodID.add(1);

        emit NewPeriodStarted(_currentPeriodID);
    }

    function recoverTokens(
        address tokenAddress,
        address recoverAddress
    ) external onlyOwner {
        _validateRecoverAddress(recoverAddress);
        require(tokenAddress != address(syndex()), "Must use another function");

        IERC20 token = IERC20(tokenAddress);

        uint tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "No tokens to recover");

        token.safeTransfer(recoverAddress, tokenBalance);

        emit TokensRecovered(tokenAddress, recoverAddress, tokenBalance);
    }

    function recoverUnassignedRewardTokens(
        address recoverAddress
    ) external onlyOwner {
        _validateRecoverAddress(recoverAddress);

        uint tokenBalance = syndex().balanceOf(address(this));
        require(tokenBalance > 0, "No tokens to recover");

        uint unassignedBalance = tokenBalance.sub(_balanceAssignedToRewards);
        require(unassignedBalance > 0, "No tokens to recover");

        syndex().safeTransfer(recoverAddress, unassignedBalance);

        emit UnassignedRewardTokensRecovered(recoverAddress, unassignedBalance);
    }

    function recoverAssignedRewardTokensAndDestroyPeriod(
        address recoverAddress,
        uint periodID
    ) external onlyOwner {
        _validateRecoverAddress(recoverAddress);
        require(periodID < _currentPeriodID, "Cannot recover from active");

        Period storage period = _periods[periodID];
        require(period.availableRewards > 0, "No rewards available to recover");

        uint amount = period.availableRewards;
        syndex().safeTransfer(recoverAddress, amount);

        _balanceAssignedToRewards = _balanceAssignedToRewards.sub(amount);

        delete _periods[periodID];

        emit AssignedRewardTokensRecovered(recoverAddress, amount, periodID);
    }

    function notifyRewardAmount(uint256 reward) external override {}

    function _validateRecoverAddress(address recoverAddress) internal view {
        if (recoverAddress == address(0) || recoverAddress == address(this)) {
            revert("Invalid recover address");
        }
    }

    function setPeriodController(
        address newPeriodController
    ) external onlyOwner {
        require(newPeriodController != address(0), "Invalid period controller");

        _periodController = newPeriodController;

        emit PeriodControllerChanged(newPeriodController);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyPeriodController() {
        require(
            msg.sender == _periodController,
            "Caller not period controller"
        );
        _;
    }

    modifier onlyExchanger() {
        require(
            msg.sender == address(exchanger()),
            "Only Exchanger can invoke this"
        );
        _;
    }

    /* ========== EVENTS ========== */

    event ExchangeFeeRecorded(
        address indexed account,
        uint amount,
        uint periodID
    );
    event RewardsClaimed(address indexed account, uint amount, uint periodID);
    event NewPeriodStarted(uint periodID);
    event PeriodFinalizedWithRewards(uint periodID, uint rewards);
    event TokensRecovered(
        address tokenAddress,
        address recoverAddress,
        uint amount
    );
    event UnassignedRewardTokensRecovered(address recoverAddress, uint amount);
    event AssignedRewardTokensRecovered(
        address recoverAddress,
        uint amount,
        uint periodID
    );
    event PeriodControllerChanged(address newPeriodController);
}
