// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IERC20.sol";
import "../interfaces/IFeePool.sol";
import "../interfaces/ISynDex.sol";
import "../interfaces/IRewardEscrow.sol";

import "../libraries/SafeDecimalMath.sol";

contract RewardEscrow is Ownable, IRewardEscrow {
    using SafeMath for uint;

    /* The corresponding SynDex contract. */
    ISynDex public syndex;

    IFeePool public feePool;

    /* Lists of (timestamp, quantity) pairs per account, sorted in ascending time order.
     * These are the times at which each given quantity of SFCX vests. */
    mapping(address => uint[2][]) public vestingSchedules;

    /* An account's total escrowed syndex balance to save recomputing this for fee extraction purposes. */
    mapping(address => uint) public totalEscrowedAccountBalance;

    /* An account's total vested reward syndex. */
    mapping(address => uint) public totalVestedAccountBalance;

    /* The total remaining escrowed balance, for verifying the actual syndex balance of this contract against. */
    uint public totalEscrowedBalance;

    uint internal constant TIME_INDEX = 0;
    uint internal constant QUANTITY_INDEX = 1;

    /* Limit vesting entries to disallow unbounded iteration over vesting schedules.
     * There are 5 years of the supply schedule */
    uint public constant MAX_VESTING_ENTRIES = 52 * 5;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _syndex,
        address _feePool
    ) Ownable(_owner) {
        syndex = ISynDex(_syndex);
        feePool = IFeePool(_feePool);
    }

    /* ========== SETTERS ========== */

    /**
     * @notice set the syndex contract address as we need to transfer SFCX when the user vests
     */
    function setSynDex(ISynDex _syndex) external onlyOwner {
        syndex = _syndex;
        emit SynDexUpdated(address(_syndex));
    }

    /**
     * @notice set the FeePool contract as it is the only authority to be able to call
     * appendVestingEntry with the onlyFeePool modifer
     */
    function setFeePool(IFeePool _feePool) external onlyOwner {
        feePool = _feePool;
        emit FeePoolUpdated(address(_feePool));
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice A simple alias to totalEscrowedAccountBalance: provides ERC20 balance integration.
     */
    function balanceOf(address account) public view returns (uint) {
        return totalEscrowedAccountBalance[account];
    }

    function _numVestingEntries(address account) internal view returns (uint) {
        return vestingSchedules[account].length;
    }

    /**
     * @notice The number of vesting dates in an account's schedule.
     */
    function numVestingEntries(address account) external view returns (uint) {
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
        uint len = _numVestingEntries(account);
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
        if (index == _numVestingEntries(account)) {
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

    /**
     * @notice return the full vesting schedule entries vest for a given user.
     * @dev For DApps to display the vesting schedule for the
     * inflationary supply over 5 years. Solidity cant return variable length arrays
     * so this is returning pairs of data. Vesting Time at [0] and quantity at [1] and so on
     */
    function checkAccountSchedule(
        address account
    ) public view returns (uint[520] memory) {
        uint[520] memory _result;
        uint schedules = _numVestingEntries(account);
        for (uint i = 0; i < schedules; i++) {
            uint[2] memory pair = getVestingScheduleEntry(account, i);
            _result[i * 2] = pair[0];
            _result[i * 2 + 1] = pair[1];
        }
        return _result;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function _appendVestingEntry(address account, uint quantity) internal {
        /* No empty or already-passed vesting entries allowed. */
        require(quantity != 0, "Quantity cannot be zero");

        /* There must be enough balance in the contract to provide for the vesting entry. */
        totalEscrowedBalance = totalEscrowedBalance.add(quantity);
        require(
            totalEscrowedBalance <=
                IERC20(address(syndex)).balanceOf(address(this)),
            "Must be enough balance in the contract to provide for the vesting entry"
        );

        /* Disallow arbitrarily long vesting schedules in light of the gas limit. */
        uint scheduleLength = vestingSchedules[account].length;
        require(
            scheduleLength <= MAX_VESTING_ENTRIES,
            "Vesting schedule is too long"
        );

        /* Escrow the tokens for 1 year. */
        uint time = block.timestamp + 52 weeks;

        if (scheduleLength == 0) {
            totalEscrowedAccountBalance[account] = quantity;
        } else {
            /* Disallow adding new vested SFCX earlier than the last one.
             * Since entries are only appended, this means that no vesting date can be repeated. */
            require(
                getVestingTime(account, scheduleLength - 1) < time,
                "Cannot add new vested entries earlier than the last one"
            );
            totalEscrowedAccountBalance[account] = totalEscrowedAccountBalance[
                account
            ].add(quantity);
        }

        vestingSchedules[account].push([time, quantity]);

        emit VestingEntryCreated(account, block.timestamp, quantity);
    }

    /**
     * @notice Add a new vesting entry at a given time and quantity to an account's schedule.
     * @dev A call to this should accompany a previous successful call to syndex.transfer(rewardEscrow, amount),
     * to ensure that when the funds are withdrawn, there is enough balance.
     * Note; although this function could technically be used to produce unbounded
     * arrays, it's only withinn the 4 year period of the weekly inflation schedule.
     * @param account The account to append a new vesting entry to.
     * @param quantity The quantity of SFCX that will be escrowed.
     */
    function appendVestingEntry(
        address account,
        uint quantity
    ) external onlyFeePool {
        _appendVestingEntry(account, quantity);
    }

    /**
     * @notice Allow a user to withdraw any SFCX in their schedule that have vested.
     */
    function vest() external {
        uint numEntries = _numVestingEntries(msg.sender);
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
            totalEscrowedBalance = totalEscrowedBalance.sub(total);
            totalEscrowedAccountBalance[
                msg.sender
            ] = totalEscrowedAccountBalance[msg.sender].sub(total);
            totalVestedAccountBalance[msg.sender] = totalVestedAccountBalance[
                msg.sender
            ].add(total);
            IERC20(address(syndex)).transfer(msg.sender, total);
            emit Vested(msg.sender, block.timestamp, total);
        }
    }

    /* ========== MODIFIERS ========== */

    modifier onlyFeePool() {
        bool isFeePool = msg.sender == address(feePool);

        require(
            isFeePool,
            "Only the FeePool contracts can perform this action"
        );
        _;
    }

    /* ========== EVENTS ========== */

    event SynDexUpdated(address newSynDex);

    event FeePoolUpdated(address newFeePool);

    event Vested(address indexed beneficiary, uint time, uint value);

    event VestingEntryCreated(
        address indexed beneficiary,
        uint time,
        uint value
    );
}
