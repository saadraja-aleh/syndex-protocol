// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./LimitedSetup.sol";

import "../interfaces/IERC20.sol";
import "../interfaces/ISynDex.sol";
import "../interfaces/IHasBalance.sol";

import "../libraries/SafeDecimalMath.sol";

contract SynDexEscrow is Ownable, LimitedSetup(8 weeks), IHasBalance {
    using SafeMath for uint;

    /* The corresponding SynDex contract. */
    ISynDex public syndex;

    /* Lists of (timestamp, quantity) pairs per account, sorted in ascending time order.
     * These are the times at which each given quantity of SFCX vests. */
    mapping(address => uint[2][]) public vestingSchedules;

    /* An account's total vested syndex balance to save recomputing this for fee extraction purposes. */
    mapping(address => uint) public totalVestedAccountBalance;

    /* The total remaining vested balance, for verifying the actual syndex balance of this contract against. */
    uint public totalVestedBalance;

    uint public constant TIME_INDEX = 0;
    uint public constant QUANTITY_INDEX = 1;

    /* Limit vesting entries to disallow unbounded iteration over vesting schedules. */
    uint public constant MAX_VESTING_ENTRIES = 20;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _owner, ISynDex _syndex) Ownable(_owner) {
        syndex = _syndex;
    }

    /* ========== SETTERS ========== */

    function setSynDex(ISynDex _syndex) external onlyOwner {
        syndex = _syndex;
        emit SynDexUpdated(address(_syndex));
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice A simple alias to totalVestedAccountBalance: provides ERC20 balance integration.
     */
    function balanceOf(address account) public view returns (uint) {
        return totalVestedAccountBalance[account];
    }

    /**
     * @notice The number of vesting dates in an account's schedule.
     */
    function numVestingEntries(address account) public view returns (uint) {
        return vestingSchedules[account].length;
    }

    /**
     * @notice Get a particular schedule entry for an account.
     * @return A pair of uints: (timestamp, syndex quantity).
     */
    function getVestingScheduleEntry(
        address account,
        uint index
    ) public view returns (uint[2] memory) {
        return vestingSchedules[account][index];
    }

    /**
     * @notice Get the time at which a given schedule entry will vest.
     */
    function getVestingTime(
        address account,
        uint index
    ) public view returns (uint) {
        return getVestingScheduleEntry(account, index)[TIME_INDEX];
    }

    /**
     * @notice Get the quantity of SFCX associated with a given schedule entry.
     */
    function getVestingQuantity(
        address account,
        uint index
    ) public view returns (uint) {
        return getVestingScheduleEntry(account, index)[QUANTITY_INDEX];
    }

    /**
     * @notice Obtain the index of the next schedule entry that will vest for a given user.
     */
    function getNextVestingIndex(address account) public view returns (uint) {
        uint len = numVestingEntries(account);
        for (uint i = 0; i < len; i++) {
            if (getVestingTime(account, i) != 0) {
                return i;
            }
        }
        return len;
    }

    /**
     * @notice Obtain the next schedule entry that will vest for a given user.
     * @return A pair of uints: (timestamp, syndex quantity). */
    function getNextVestingEntry(
        address account
    ) public view returns (uint[2] memory) {
        uint index = getNextVestingIndex(account);
        if (index == numVestingEntries(account)) {
            return [uint(0), 0];
        }
        return getVestingScheduleEntry(account, index);
    }

    /**
     * @notice Obtain the time at which the next schedule entry will vest for a given user.
     */
    function getNextVestingTime(address account) external view returns (uint) {
        return getNextVestingEntry(account)[TIME_INDEX];
    }

    /**
     * @notice Obtain the quantity which the next schedule entry will vest for a given user.
     */
    function getNextVestingQuantity(
        address account
    ) external view returns (uint) {
        return getNextVestingEntry(account)[QUANTITY_INDEX];
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Destroy the vesting information associated with an account.
     */
    function purgeAccount(address account) external onlyOwner onlyDuringSetup {
        delete vestingSchedules[account];
        totalVestedBalance = totalVestedBalance.sub(
            totalVestedAccountBalance[account]
        );
        delete totalVestedAccountBalance[account];
    }

    /**
     * @notice Add a new vesting entry at a given time and quantity to an account's schedule.
     * @dev A call to this should be accompanied by either enough balance already available
     * in this contract, or a corresponding call to syndex.endow(), to ensure that when
     * the funds are withdrawn, there is enough balance, as well as correctly calculating
     * the fees.
     * This may only be called by the owner during the contract's setup period.
     * Note; although this function could technically be used to produce unbounded
     * arrays, it's only in the foundation's command to add to these lists.
     * @param account The account to append a new vesting entry to.
     * @param time The absolute unix timestamp after which the vested quantity may be withdrawn.
     * @param quantity The quantity of SFCX that will vest.
     */
    function appendVestingEntry(
        address account,
        uint time,
        uint quantity
    ) public onlyOwner onlyDuringSetup {
        /* No empty or already-passed vesting entries allowed. */
        require(block.timestamp < time, "Time must be in the future");
        require(quantity != 0, "Quantity cannot be zero");

        /* There must be enough balance in the contract to provide for the vesting entry. */
        totalVestedBalance = totalVestedBalance.add(quantity);
        require(
            totalVestedBalance <=
                IERC20(address(syndex)).balanceOf(address(this)),
            "Must be enough balance in the contract to provide for the vesting entry"
        );

        /* Disallow arbitrarily long vesting schedules in light of the gas limit. */
        uint scheduleLength = vestingSchedules[account].length;
        require(
            scheduleLength <= MAX_VESTING_ENTRIES,
            "Vesting schedule is too long"
        );

        if (scheduleLength == 0) {
            totalVestedAccountBalance[account] = quantity;
        } else {
            /* Disallow adding new vested SFCX earlier than the last one.
             * Since entries are only appended, this means that no vesting date can be repeated. */
            require(
                getVestingTime(account, numVestingEntries(account) - 1) < time,
                "Cannot add new vested entries earlier than the last one"
            );
            totalVestedAccountBalance[account] = totalVestedAccountBalance[
                account
            ].add(quantity);
        }

        vestingSchedules[account].push([time, quantity]);
    }

    /**
     * @notice Construct a vesting schedule to release a quantities of SFCX
     * over a series of intervals.
     * @dev Assumes that the quantities are nonzero
     * and that the sequence of timestamps is strictly increasing.
     * This may only be called by the owner during the contract's setup period.
     */
    function addVestingSchedule(
        address account,
        uint[] calldata times,
        uint[] calldata quantities
    ) external onlyOwner onlyDuringSetup {
        for (uint i = 0; i < times.length; i++) {
            appendVestingEntry(account, times[i], quantities[i]);
        }
    }

    /**
     * @notice Allow a user to withdraw any SFCX in their schedule that have vested.
     */
    function vest() external {
        uint numEntries = numVestingEntries(msg.sender);
        uint total;
        for (uint i = 0; i < numEntries; i++) {
            uint time = getVestingTime(msg.sender, i);
            /* The list is sorted; when we reach the first future time, bail out. */
            if (time > block.timestamp) {
                break;
            }
            uint qty = getVestingQuantity(msg.sender, i);
            if (qty > 0) {
                vestingSchedules[msg.sender][i] = [0, 0];
                total = total.add(qty);
            }
        }

        if (total != 0) {
            totalVestedBalance = totalVestedBalance.sub(total);
            totalVestedAccountBalance[msg.sender] = totalVestedAccountBalance[
                msg.sender
            ].sub(total);
            IERC20(address(syndex)).transfer(msg.sender, total);
            emit Vested(msg.sender, block.timestamp, total);
        }
    }

    /* ========== EVENTS ========== */

    event SynDexUpdated(address newSynDex);

    event Vested(address indexed beneficiary, uint time, uint value);
}
