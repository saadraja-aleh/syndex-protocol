// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./MixinResolver.sol";

import "../interfaces/IERC20.sol";
import "../interfaces/IDepot.sol";
import "../interfaces/IExchangeRates.sol";

import "../libraries/SafeDecimalMath.sol";

contract Depot is Ownable, Pausable, ReentrancyGuard, MixinResolver, IDepot {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    bytes32 internal constant SFCX = "SFCX";
    bytes32 internal constant ETH = "ETH";

    /* ========== STATE VARIABLES ========== */

    // Address where the ether and Synths raised for selling SFCX is transfered to
    // Any ether raised for selling Synths gets sent back to whoever deposited the Synths,
    // and doesn't have anything to do with this address.
    address payable public fundsWallet;

    /* Stores deposits from users. */
    struct SynthDepositEntry {
        // The user that made the deposit
        address payable user;
        // The amount (in Synths) that they deposited
        uint amount;
    }

    /* User deposits are sold on a FIFO (First in First out) basis. When users deposit
       synths with us, they get added this queue, which then gets fulfilled in order.
       Conceptually this fits well in an array, but then when users fill an order we
       end up copying the whole array around, so better to use an index mapping instead
       for gas performance reasons.

       The indexes are specified (inclusive, exclusive), so (0, 0) means there's nothing
       in the array, and (3, 6) means there are 3 elements at 3, 4, and 5. You can obtain
       the length of the "array" by querying depositEndIndex - depositStartIndex. All index
       operations use safeAdd, so there is no way to overflow, so that means there is a
       very large but finite amount of deposits this contract can handle before it fills up. */
    mapping(uint => SynthDepositEntry) public deposits;
    // The starting index of our queue inclusive
    uint public depositStartIndex;
    // The ending index of our queue exclusive
    uint public depositEndIndex;

    /* This is a convenience variable so users and dApps can just query how much cfUSD
       we have available for purchase without having to iterate the mapping with a
       O(n) amount of calls for something we'll probably want to display quite regularly. */
    uint public totalSellableDeposits;

    // The minimum amount of cfUSD required to enter the FiFo queue
    uint public minimumDepositAmount = 50 * SafeDecimalMath.unit();

    // A cap on the amount of cfUSD you can buy with ETH in 1 transaction
    uint public maxEthPurchase = 500 * SafeDecimalMath.unit();

    // If a user deposits a synth amount < the minimumDepositAmount the contract will keep
    // the total of small deposits which will not be sold on market and the sender
    // must call withdrawMyDepositedSynths() to get them back.
    mapping(address => uint) public smallDeposits;

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_SYNTHCFUSD = "SynthcfUSD";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_SYNDEX = "SynDex";

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address payable _fundsWallet,
        address _resolver
    ) Ownable(_owner) Pausable() MixinResolver(_resolver) {
        fundsWallet = _fundsWallet;
    }

    /* ========== SETTERS ========== */

    function setMaxEthPurchase(uint _maxEthPurchase) external onlyOwner {
        maxEthPurchase = _maxEthPurchase;
        emit MaxEthPurchaseUpdated(maxEthPurchase);
    }

    /**
     * @notice Set the funds wallet where ETH raised is held
     * @param _fundsWallet The new address to forward ETH and Synths to
     */
    function setFundsWallet(address payable _fundsWallet) external onlyOwner {
        fundsWallet = _fundsWallet;
        emit FundsWalletUpdated(fundsWallet);
    }

    /**
     * @notice Set the minimum deposit amount required to depoist cfUSD into the FIFO queue
     * @param _amount The new new minimum number of cfUSD required to deposit
     */
    function setMinimumDepositAmount(uint _amount) external onlyOwner {
        // Do not allow us to set it less than 1 dollar opening up to fractional desposits in the queue again
        require(
            _amount > SafeDecimalMath.unit(),
            "Minimum deposit amount must be greater than UNIT"
        );
        minimumDepositAmount = _amount;
        emit MinimumDepositAmountUpdated(minimumDepositAmount);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Fallback function (exchanges ETH to cfUSD)
     */
    fallback() external payable nonReentrant rateNotInvalid(ETH) whenNotPaused {
        _exchangeEtherForSynths();
    }

    receive() external payable {}

    /**
     * @notice Exchange ETH to cfUSD.
     */
    /* solhint-disable multiple-sends, reentrancy */
    function exchangeEtherForSynths()
        external
        payable
        nonReentrant
        rateNotInvalid(ETH)
        whenNotPaused
        returns (
            uint // Returns the number of Synths (cfUSD) received
        )
    {
        return _exchangeEtherForSynths();
    }

    function _exchangeEtherForSynths() internal returns (uint) {
        require(
            msg.value <= maxEthPurchase,
            "ETH amount above maxEthPurchase limit"
        );
        uint ethToSend;

        // The multiplication works here because exchangeRates().rateForCurrency(ETH) is specified in
        // 18 decimal places, just like our currency base.
        uint requestedToPurchase = msg.value.multiplyDecimal(
            exchangeRates().rateForCurrency(ETH)
        );
        uint remainingToFulfill = requestedToPurchase;

        // Iterate through our outstanding deposits and sell them one at a time.
        for (
            uint i = depositStartIndex;
            remainingToFulfill > 0 && i < depositEndIndex;
            i++
        ) {
            SynthDepositEntry memory deposit = deposits[i];

            // If it's an empty spot in the queue from a previous withdrawal, just skip over it and
            // update the queue. It's already been deleted.
            if (deposit.user == address(0)) {
                depositStartIndex = depositStartIndex.add(1);
            } else {
                // If the deposit can more than fill the order, we can do this
                // without touching the structure of our queue.
                if (deposit.amount > remainingToFulfill) {
                    // Ok, this deposit can fulfill the whole remainder. We don't need
                    // to change anything about our queue we can just fulfill it.
                    // Subtract the amount from our deposit and total.
                    uint newAmount = deposit.amount.sub(remainingToFulfill);
                    deposits[i] = SynthDepositEntry({
                        user: deposit.user,
                        amount: newAmount
                    });

                    totalSellableDeposits = totalSellableDeposits.sub(
                        remainingToFulfill
                    );

                    // Transfer the ETH to the depositor. Send is used instead of transfer
                    // so a non payable contract won't block the FIFO queue on a failed
                    // ETH payable for synths transaction. The proceeds to be sent to the
                    // syndex foundation funds wallet. This is to protect all depositors
                    // in the queue in this rare case that may occur.
                    ethToSend = remainingToFulfill.divideDecimal(
                        exchangeRates().rateForCurrency(ETH)
                    );

                    // We need to use send here instead of transfer because transfer reverts
                    // if the recipient is a non-payable contract. Send will just tell us it
                    // failed by returning false at which point we can continue.
                    if (!deposit.user.send(ethToSend)) {
                        fundsWallet.transfer(ethToSend);
                        emit NonPayableContract(deposit.user, ethToSend);
                    } else {
                        emit ClearedDeposit(
                            msg.sender,
                            deposit.user,
                            ethToSend,
                            remainingToFulfill,
                            i
                        );
                    }

                    // And the Synths to the recipient.
                    // Note: Fees are calculated by the Synth contract, so when
                    //       we request a specific transfer here, the fee is
                    //       automatically deducted and sent to the fee pool.
                    synthcfUSD().transfer(msg.sender, remainingToFulfill);

                    // And we have nothing left to fulfill on this order.
                    remainingToFulfill = 0;
                } else if (deposit.amount <= remainingToFulfill) {
                    // We need to fulfill this one in its entirety and kick it out of the queue.
                    // Start by kicking it out of the queue.
                    // Free the storage because we can.
                    delete deposits[i];
                    // Bump our start index forward one.
                    depositStartIndex = depositStartIndex.add(1);
                    // We also need to tell our total it's decreased
                    totalSellableDeposits = totalSellableDeposits.sub(
                        deposit.amount
                    );

                    // Now fulfill by transfering the ETH to the depositor. Send is used instead of transfer
                    // so a non payable contract won't block the FIFO queue on a failed
                    // ETH payable for synths transaction. The proceeds to be sent to the
                    // syndex foundation funds wallet. This is to protect all depositors
                    // in the queue in this rare case that may occur.
                    ethToSend = deposit.amount.divideDecimal(
                        exchangeRates().rateForCurrency(ETH)
                    );

                    // We need to use send here instead of transfer because transfer reverts
                    // if the recipient is a non-payable contract. Send will just tell us it
                    // failed by returning false at which point we can continue.
                    if (!deposit.user.send(ethToSend)) {
                        fundsWallet.transfer(ethToSend);
                        emit NonPayableContract(deposit.user, ethToSend);
                    } else {
                        emit ClearedDeposit(
                            msg.sender,
                            deposit.user,
                            ethToSend,
                            deposit.amount,
                            i
                        );
                    }

                    // And the Synths to the recipient.
                    // Note: Fees are calculated by the Synth contract, so when
                    //       we request a specific transfer here, the fee is
                    //       automatically deducted and sent to the fee pool.
                    synthcfUSD().transfer(msg.sender, deposit.amount);

                    // And subtract the order from our outstanding amount remaining
                    // for the next iteration of the loop.
                    remainingToFulfill = remainingToFulfill.sub(deposit.amount);
                }
            }
        }

        // Ok, if we're here and 'remainingToFulfill' isn't zero, then
        // we need to refund the remainder of their ETH back to them.
        if (remainingToFulfill > 0) {
            payable(msg.sender).transfer(
                remainingToFulfill.divideDecimal(
                    exchangeRates().rateForCurrency(ETH)
                )
            );
        }

        // How many did we actually give them?
        uint fulfilled = requestedToPurchase.sub(remainingToFulfill);

        if (fulfilled > 0) {
            // Now tell everyone that we gave them that many (only if the amount is greater than 0).
            emit Exchange("ETH", msg.value, "cfUSD", fulfilled);
        }

        return fulfilled;
    }

    /* solhint-enable multiple-sends, reentrancy */

    /**
     * @notice Exchange ETH to cfUSD while insisting on a particular rate. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rate.
     * @param guaranteedRate The exchange rate (ether price) which must be honored or the call will revert.
     */
    function exchangeEtherForSynthsAtRate(
        uint guaranteedRate
    )
        external
        payable
        rateNotInvalid(ETH)
        whenNotPaused
        returns (
            uint // Returns the number of Synths (cfUSD) received
        )
    {
        require(
            guaranteedRate == exchangeRates().rateForCurrency(ETH),
            "Guaranteed rate would not be received"
        );

        return _exchangeEtherForSynths();
    }

    function _exchangeEtherForSFCX() internal returns (uint) {
        // How many SFCX are they going to be receiving?
        uint syndexToSend = syndexReceivedForEther(msg.value);

        // Store the ETH in our funds wallet
        fundsWallet.transfer(msg.value);

        // And send them the SFCX.
        syndex().transfer(msg.sender, syndexToSend);

        emit Exchange("ETH", msg.value, "SFCX", syndexToSend);

        return syndexToSend;
    }

    /**
     * @notice Exchange ETH to SFCX.
     */
    function exchangeEtherForSFCX()
        external
        payable
        rateNotInvalid(SFCX)
        rateNotInvalid(ETH)
        whenNotPaused
        returns (
            uint // Returns the number of SFCX received
        )
    {
        return _exchangeEtherForSFCX();
    }

    /**
     * @notice Exchange ETH to SFCX while insisting on a particular set of rates. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rates.
     * @param guaranteedEtherRate The ether exchange rate which must be honored or the call will revert.
     * @param guaranteedSynDexRate The syndex exchange rate which must be honored or the call will revert.
     */
    function exchangeEtherForSFCXAtRate(
        uint guaranteedEtherRate,
        uint guaranteedSynDexRate
    )
        external
        payable
        rateNotInvalid(SFCX)
        rateNotInvalid(ETH)
        whenNotPaused
        returns (
            uint // Returns the number of SFCX received
        )
    {
        require(
            guaranteedEtherRate == exchangeRates().rateForCurrency(ETH),
            "Guaranteed ether rate would not be received"
        );
        require(
            guaranteedSynDexRate == exchangeRates().rateForCurrency(SFCX),
            "Guaranteed syndex rate would not be received"
        );

        return _exchangeEtherForSFCX();
    }

    function _exchangeSynthsForSFCX(uint synthAmount) internal returns (uint) {
        // How many SFCX are they going to be receiving?
        uint syndexToSend = syndexReceivedForSynths(synthAmount);

        // Ok, transfer the Synths to our funds wallet.
        // These do not go in the deposit queue as they aren't for sale as such unless
        // they're sent back in from the funds wallet.
        synthcfUSD().transferFrom(msg.sender, fundsWallet, synthAmount);

        // And send them the SFCX.
        syndex().transfer(msg.sender, syndexToSend);

        emit Exchange("cfUSD", synthAmount, "SFCX", syndexToSend);

        return syndexToSend;
    }

    /**
     * @notice Exchange cfUSD for SFCX
     * @param synthAmount The amount of synths the user wishes to exchange.
     */
    function exchangeSynthsForSFCX(
        uint synthAmount
    )
        external
        rateNotInvalid(SFCX)
        whenNotPaused
        returns (
            uint // Returns the number of SFCX received
        )
    {
        return _exchangeSynthsForSFCX(synthAmount);
    }

    /**
     * @notice Exchange cfUSD for SFCX while insisting on a particular rate. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rate.
     * @param synthAmount The amount of synths the user wishes to exchange.
     * @param guaranteedRate A rate (syndex price) the caller wishes to insist upon.
     */
    function exchangeSynthsForSFCXAtRate(
        uint synthAmount,
        uint guaranteedRate
    )
        external
        rateNotInvalid(SFCX)
        whenNotPaused
        returns (
            uint // Returns the number of SFCX received
        )
    {
        require(
            guaranteedRate == exchangeRates().rateForCurrency(SFCX),
            "Guaranteed rate would not be received"
        );

        return _exchangeSynthsForSFCX(synthAmount);
    }

    /**
     * @notice Allows the owner to withdraw SFCX from this contract if needed.
     * @param amount The amount of SFCX to attempt to withdraw (in 18 decimal places).
     */
    function withdrawSynDex(uint amount) external onlyOwner {
        syndex().transfer(owner(), amount);

        // We don't emit our own events here because we assume that anyone
        // who wants to watch what the Depot is doing can
        // just watch ERC20 events from the Synth and/or SynDex contracts
        // filtered to our address.
    }

    /**
     * @notice Allows a user to withdraw all of their previously deposited synths from this contract if needed.
     *         Developer note: We could keep an index of address to deposits to make this operation more efficient
     *         but then all the other operations on the queue become less efficient. It's expected that this
     *         function will be very rarely used, so placing the inefficiency here is intentional. The usual
     *         use case does not involve a withdrawal.
     */
    function withdrawMyDepositedSynths() external {
        uint synthsToSend = 0;

        for (uint i = depositStartIndex; i < depositEndIndex; i++) {
            SynthDepositEntry memory deposit = deposits[i];

            if (deposit.user == msg.sender) {
                // The user is withdrawing this deposit. Remove it from our queue.
                // We'll just leave a gap, which the purchasing logic can walk past.
                synthsToSend = synthsToSend.add(deposit.amount);
                delete deposits[i];
                //Let the DApps know we've removed this deposit
                emit SynthDepositRemoved(deposit.user, deposit.amount, i);
            }
        }

        // Update our total
        totalSellableDeposits = totalSellableDeposits.sub(synthsToSend);

        // Check if the user has tried to send deposit amounts < the minimumDepositAmount to the FIFO
        // queue which would have been added to this mapping for withdrawal only
        synthsToSend = synthsToSend.add(smallDeposits[msg.sender]);
        smallDeposits[msg.sender] = 0;

        // If there's nothing to do then go ahead and revert the transaction
        require(synthsToSend > 0, "You have no deposits to withdraw.");

        // Send their deposits back to them (minus fees)
        synthcfUSD().transfer(msg.sender, synthsToSend);

        emit SynthWithdrawal(msg.sender, synthsToSend);
    }

    /**
     * @notice depositSynths: Allows users to deposit synths via the approve / transferFrom workflow
     * @param amount The amount of cfUSD you wish to deposit (must have been approved first)
     */
    function depositSynths(uint amount) external {
        // Grab the amount of synths. Will fail if not approved first
        synthcfUSD().transferFrom(msg.sender, address(this), amount);

        // A minimum deposit amount is designed to protect purchasers from over paying
        // gas for fullfilling multiple small synth deposits
        if (amount < minimumDepositAmount) {
            // We cant fail/revert the transaction or send the synths back in a reentrant call.
            // So we will keep your synths balance seperate from the FIFO queue so you can withdraw them
            smallDeposits[msg.sender] = smallDeposits[msg.sender].add(amount);

            emit SynthDepositNotAccepted(
                msg.sender,
                amount,
                minimumDepositAmount
            );
        } else {
            // Ok, thanks for the deposit, let's queue it up.
            deposits[depositEndIndex] = SynthDepositEntry({
                user: payable(msg.sender),
                amount: amount
            });
            emit SynthDeposit(msg.sender, amount, depositEndIndex);

            // Walk our index forward as well.
            depositEndIndex = depositEndIndex.add(1);

            // And add it to our total.
            totalSellableDeposits = totalSellableDeposits.add(amount);
        }
    }

    /* ========== VIEWS ========== */

    function resolverAddressesRequired()
        public
        view
        override
        returns (bytes32[] memory addresses)
    {
        addresses = new bytes32[](3);
        addresses[0] = CONTRACT_SYNTHCFUSD;
        addresses[1] = CONTRACT_EXRATES;
        addresses[2] = CONTRACT_SYNDEX;
    }

    /**
     * @notice Calculate how many SFCX you will receive if you transfer
     *         an amount of synths.
     * @param amount The amount of synths (in 18 decimal places) you want to ask about
     */
    function syndexReceivedForSynths(
        uint amount
    ) public view returns (uint) {
        // And what would that be worth in SFCX based on the current price?
        return amount.divideDecimal(exchangeRates().rateForCurrency(SFCX));
    }

    /**
     * @notice Calculate how many SFCX you will receive if you transfer
     *         an amount of ether.
     * @param amount The amount of ether (in wei) you want to ask about
     */
    function syndexReceivedForEther(uint amount) public view returns (uint) {
        // How much is the ETH they sent us worth in cfUSD (ignoring the transfer fee)?
        uint valueSentInSynths = amount.multiplyDecimal(
            exchangeRates().rateForCurrency(ETH)
        );

        // Now, how many SFCX will that USD amount buy?
        return syndexReceivedForSynths(valueSentInSynths);
    }

    /**
     * @notice Calculate how many synths you will receive if you transfer
     *         an amount of ether.
     * @param amount The amount of ether (in wei) you want to ask about
     */
    function synthsReceivedForEther(uint amount) public view returns (uint) {
        // How many synths would that amount of ether be worth?
        return amount.multiplyDecimal(exchangeRates().rateForCurrency(ETH));
    }

    /* ========== INTERNAL VIEWS ========== */

    function synthcfUSD() internal view returns (IERC20) {
        return IERC20(requireAndGetAddress(CONTRACT_SYNTHCFUSD));
    }

    function syndex() internal view returns (IERC20) {
        return IERC20(requireAndGetAddress(CONTRACT_SYNDEX));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES));
    }

    // ========== MODIFIERS ==========

    modifier rateNotInvalid(bytes32 currencyKey) {
        require(
            !exchangeRates().rateIsInvalid(currencyKey),
            "Rate invalid or not a synth"
        );
        _;
    }

    /* ========== EVENTS ========== */

    event MaxEthPurchaseUpdated(uint amount);
    event FundsWalletUpdated(address newFundsWallet);
    event Exchange(
        string fromCurrency,
        uint fromAmount,
        string toCurrency,
        uint toAmount
    );
    event SynthWithdrawal(address user, uint amount);
    event SynthDeposit(
        address indexed user,
        uint amount,
        uint indexed depositIndex
    );
    event SynthDepositRemoved(
        address indexed user,
        uint amount,
        uint indexed depositIndex
    );
    event SynthDepositNotAccepted(address user, uint amount, uint minimum);
    event MinimumDepositAmountUpdated(uint amount);
    event NonPayableContract(address indexed receiver, uint amount);
    event ClearedDeposit(
        address indexed fromAddress,
        address indexed toAddress,
        uint fromETHAmount,
        uint toAmount,
        uint indexed depositIndex
    );
}
