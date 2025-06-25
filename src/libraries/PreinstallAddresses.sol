// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library PreinstallAddresses {
    /// @notice The address of deployer available on all optimism chains
    address internal constant CREATE2_DEPLOYER = 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2;

    /// @notice The dertministic address of the Permit2 contract
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
}
