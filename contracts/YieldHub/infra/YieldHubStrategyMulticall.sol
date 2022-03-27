// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "../interfaces/yieldhub/IVault.sol";

contract YieldHubStrategyMulticall {

    function getStrategy(address[] calldata vaults) external view returns (address[] memory) {
        address[] memory strategies = new address[](vaults.length);

        for (uint i = 0; i < vaults.length; i++) {
            strategies[i] = address(IVault(vaults[i]).strategy());
        }

        return strategies;
    }
}