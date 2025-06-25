// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICreate2Deployer
/// @notice Interface for the Create2Deployer contract.
interface ICreate2Deployer {
    /// @notice Computes the address of a contract created with the given salt and code hash.
    /// @param salt The salt to use for the deployment.
    /// @param codeHash The code hash of the contract to deploy.
    /// @return The address of the deployed contract.
    function computeAddress(bytes32 salt, bytes32 codeHash) external view returns (address);

    /// @notice Deploys a contract with the given salt and code.
    /// @param value The value to send with the deployment.
    /// @param salt The salt to use for the deployment.
    function deploy(uint256 value, bytes32 salt, bytes memory code) external;
}
