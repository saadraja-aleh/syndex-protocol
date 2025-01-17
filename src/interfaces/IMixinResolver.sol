// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IMixinResolver {
    // function getAddress(bytes32 name) external view returns (address);
    // function getSynth(bytes32 key) external view returns (address);

    function refreshCache() external;

    function requireAndGetAddress(bytes32 name) external view returns (address);
}
