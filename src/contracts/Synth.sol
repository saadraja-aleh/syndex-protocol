// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./MixinResolver.sol";
import "./ExternStateToken.sol";

import "../interfaces/IIssuer.sol";
import "../interfaces/IFeePool.sol";
import "../interfaces/IExchanger.sol";
import "../interfaces/ISystemStatus.sol";
import "../interfaces/IFuturesMarketManager.sol";

contract Synth is Ownable, ExternStateToken, MixinResolver, ISynth {
    using SafeMath for uint;

    // bytes32 public constant CONTRACT_NAME = "Synth";

    /* ========== STATE VARIABLES ========== */

    // Currency key which identifies this Synth to the SynDex system
    bytes32 public currencyKey;

    uint8 public constant DECIMALS = 18;

    // Where fees are pooled in cfUSD
    address public constant FEE_ADDRESS =
        0xfeEFEEfeefEeFeefEEFEEfEeFeefEEFeeFEEFEeF;

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_SYSTEMSTATUS = "SystemStatus";
    bytes32 private constant CONTRACT_EXCHANGER = "Exchanger";
    bytes32 private constant CONTRACT_ISSUER = "Issuer";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";
    bytes32 private constant CONTRACT_FUTURESMARKETMANAGER =
        "FuturesMarketManager";

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address payable _proxy,
        TokenState _tokenState,
        string memory _tokenName,
        string memory _tokenSymbol,
        address _owner,
        bytes32 _currencyKey,
        uint _totalSupply,
        address _resolver
    )
        ExternStateToken(
            _proxy,
            _tokenState,
            _tokenName,
            _tokenSymbol,
            _totalSupply,
            DECIMALS,
            _owner
        )
        MixinResolver(_resolver)
    {
        require(_proxy != address(0), "_proxy cannot be 0");
        require(_owner != address(0), "_owner cannot be 0");

        currencyKey = _currencyKey;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function transfer(
        address to,
        uint value
    ) public onlyProxyOrInternal returns (bool) {
        _ensureCanTransfer(messageSender, value);

        // transfers to FEE_ADDRESS will be exchanged into cfUSD and recorded as fee
        if (to == FEE_ADDRESS) {
            return _transferToFeeAddress(to, value);
        }

        // transfers to 0x address will be burned
        if (to == address(0)) {
            return _internalBurn(messageSender, value);
        }

        return super._internalTransfer(messageSender, to, value);
    }

    function transferAndSettle(
        address to,
        uint value
    ) public onlyProxyOrInternal returns (bool) {
        // Exchanger.settle ensures synth is active
        (, , uint numEntriesSettled) = exchanger().settle(
            messageSender,
            currencyKey
        );

        // Save gas instead of calling transferableSynths
        uint balanceAfter = value;

        if (numEntriesSettled > 0) {
            balanceAfter = tokenState.balanceOf(messageSender);
        }

        // Reduce the value to transfer if balance is insufficient after reclaimed
        value = value > balanceAfter ? balanceAfter : value;

        return super._internalTransfer(messageSender, to, value);
    }

    function transferFrom(
        address from,
        address to,
        uint value
    ) public onlyProxyOrInternal returns (bool) {
        _ensureCanTransfer(from, value);

        return _internalTransferFrom(from, to, value);
    }

    function transferFromAndSettle(
        address from,
        address to,
        uint value
    ) public onlyProxyOrInternal returns (bool) {
        // Exchanger.settle() ensures synth is active
        (, , uint numEntriesSettled) = exchanger().settle(from, currencyKey);

        // Save gas instead of calling transferableSynths
        uint balanceAfter = value;

        if (numEntriesSettled > 0) {
            balanceAfter = tokenState.balanceOf(from);
        }

        // Reduce the value to transfer if balance is insufficient after reclaimed
        value = value >= balanceAfter ? balanceAfter : value;

        return _internalTransferFrom(from, to, value);
    }

    /**
     * @notice _transferToFeeAddress function
     * non-cfUSD synths are exchanged into cfUSD via synthInitiatedExchange
     * notify feePool to record amount as fee paid to feePool */
    function _transferToFeeAddress(
        address to,
        uint value
    ) internal returns (bool) {
        uint amountInUSD;

        // cfUSD can be transferred to FEE_ADDRESS directly
        if (currencyKey == "cfUSD") {
            amountInUSD = value;
            super._internalTransfer(messageSender, to, value);
        } else {
            // else executeExchange synth into cfUSD and send to FEE_ADDRESS
            (amountInUSD, ) = exchanger().executeExchange(
                messageSender,
                messageSender,
                currencyKey,
                value,
                "cfUSD",
                FEE_ADDRESS,
                false,
                address(0),
                bytes32(0)
            );
        }

        // Notify feePool to record cfUSD to distribute as fees
        feePool().recordFeePaid(amountInUSD);

        return true;
    }

    function issue(
        address account,
        uint amount
    ) external virtual onlyInternalContracts {
        _internalIssue(account, amount);
    }

    function burn(
        address account,
        uint amount
    ) external virtual onlyInternalContracts {
        _internalBurn(account, amount);
    }

    function _internalIssue(address account, uint amount) internal {
        tokenState.setBalanceOf(
            account,
            tokenState.balanceOf(account).add(amount)
        );
        totalSupply = totalSupply.add(amount);
        emitTransfer(address(0), account, amount);
        emitIssued(account, amount);
    }

    function _internalBurn(
        address account,
        uint amount
    ) internal returns (bool) {
        tokenState.setBalanceOf(
            account,
            tokenState.balanceOf(account).sub(amount)
        );
        totalSupply = totalSupply.sub(amount);
        emitTransfer(account, address(0), amount);
        emitBurned(account, amount);

        return true;
    }

    // Allow owner to set the total supply on import.
    function setTotalSupply(uint amount) external optionalProxy_onlyOwner {
        totalSupply = amount;
    }

    /* ========== VIEWS ========== */

    // Note: use public visibility so that it can be invoked in a subclass
    function resolverAddressesRequired()
        public
        view
        virtual
        override
        returns (bytes32[] memory addresses)
    {
        addresses = new bytes32[](5);
        addresses[0] = CONTRACT_SYSTEMSTATUS;
        addresses[1] = CONTRACT_EXCHANGER;
        addresses[2] = CONTRACT_ISSUER;
        addresses[3] = CONTRACT_FEEPOOL;
        addresses[4] = CONTRACT_FUTURESMARKETMANAGER;
    }

    function systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(requireAndGetAddress(CONTRACT_SYSTEMSTATUS));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(requireAndGetAddress(CONTRACT_FEEPOOL));
    }

    function exchanger() internal view returns (IExchanger) {
        return IExchanger(requireAndGetAddress(CONTRACT_EXCHANGER));
    }

    function issuer() internal view returns (IIssuer) {
        return IIssuer(requireAndGetAddress(CONTRACT_ISSUER));
    }

    function futuresMarketManager()
        internal
        view
        returns (IFuturesMarketManager)
    {
        return
            IFuturesMarketManager(
                requireAndGetAddress(CONTRACT_FUTURESMARKETMANAGER)
            );
    }

    function _ensureCanTransfer(address from, uint value) internal view {
        require(
            exchanger().maxSecsLeftInWaitingPeriod(from, currencyKey) == 0,
            "Cannot transfer during waiting period"
        );
        require(
            transferableSynths(from) >= value,
            "Insufficient balance after any settlement owing"
        );
        systemStatus().requireSynthActive(currencyKey);
    }

    function transferableSynths(address account) public view returns (uint) {
        (uint reclaimAmount, , ) = exchanger().settlementOwing(
            account,
            currencyKey
        );

        // Note: ignoring rebate amount here because a settle() is required in order to
        // allow the transfer to actually work

        uint balance = tokenState.balanceOf(account);

        if (reclaimAmount > balance) {
            return 0;
        } else {
            return balance.sub(reclaimAmount);
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _internalTransferFrom(
        address from,
        address to,
        uint value
    ) internal returns (bool) {
        // Skip allowance update in case of infinite allowance
        if (tokenState.allowance(from, messageSender) != type(uint).max) {
            // Reduce the allowance by the amount we're transferring.
            // The safeSub call will handle an insufficient allowance.
            tokenState.setAllowance(
                from,
                messageSender,
                tokenState.allowance(from, messageSender).sub(value)
            );
        }

        return super._internalTransfer(from, to, value);
    }

    /* ========== MODIFIERS ========== */

    function _isInternalContract(
        address account
    ) internal view virtual returns (bool) {
        return
            account == address(feePool()) ||
            account == address(exchanger()) ||
            account == address(issuer()) ||
            account == address(futuresMarketManager());
    }

    modifier onlyInternalContracts() {
        require(
            _isInternalContract(msg.sender),
            "Only internal contracts allowed"
        );
        _;
    }

    modifier onlyProxyOrInternal() {
        _onlyProxyOrInternal();
        _;
    }

    function _onlyProxyOrInternal() internal {
        if (msg.sender == address(proxy)) {
            // allow proxy through, messageSender should be already set correctly
            return;
        } else if (_isInternalTransferCaller(msg.sender)) {
            // optionalProxy behaviour only for the internal legacy contracts
            messageSender = msg.sender;
        } else {
            revert("Only the proxy can call");
        }
    }

    /// some legacy internal contracts use transfer methods directly on implementation
    /// which isn't supported due to SIP-238 for other callers
    function _isInternalTransferCaller(
        address caller
    ) internal view returns (bool) {
        // These entries are not required or cached in order to allow them to not exist (==address(0))
        // e.g. due to not being available on L2 or at some future point in time.
        return
            // ordered to reduce gas for more frequent calls
            caller == resolver.getAddress("CollateralShort") ||
            // not used frequently
            caller == resolver.getAddress("SynthRedeemer") ||
            caller == resolver.getAddress("WrapperFactory") || // transfer not used by users
            // legacy
            caller == resolver.getAddress("NativeEtherWrapper") ||
            caller == resolver.getAddress("Depot");
    }

    /* ========== EVENTS ========== */
    event Issued(address indexed account, uint value);

    bytes32 private constant ISSUED_SIG = keccak256("Issued(address,uint256)");

    function emitIssued(address account, uint value) internal {
        proxy._emit(
            abi.encode(value),
            2,
            ISSUED_SIG,
            addressToBytes32(account),
            0,
            0
        );
    }

    event Burned(address indexed account, uint value);

    bytes32 private constant BURNED_SIG = keccak256("Burned(address,uint256)");

    function emitBurned(address account, uint value) internal {
        proxy._emit(
            abi.encode(value),
            2,
            BURNED_SIG,
            addressToBytes32(account),
            0,
            0
        );
    }
}
