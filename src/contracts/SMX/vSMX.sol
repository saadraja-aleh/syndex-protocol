// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./ERC20.sol";

/// @notice Purpose of this contract was to mint vSMX for the initial Aelin raise.
/// @dev This is a one time use contract and supply can never be increased.
contract vSMX is ERC20 {
    constructor(
        string memory _name,
        string memory _symbol,
        address _beneficiary,
        uint _amount
    ) ERC20(_name, _symbol) {
        _mint(_beneficiary, _amount);
    }
}
