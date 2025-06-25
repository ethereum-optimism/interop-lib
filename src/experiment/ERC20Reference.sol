// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@solady-v0.0.245/tokens/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

import {PredeployAddresses} from "../libraries/PredeployAddresses.sol";
import {PreinstallAddresses} from "../libraries/PreinstallAddresses.sol";

import {IL2ToL2CrossDomainMessenger} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";

/**
 * @title ERC20Reference
 * @notice An ERC20 that is a remote reference of a native ERC20 on its home chain. This can be thought
 *         about in the traditional sense of a pointer reference. On the home chain, any user can create
 *         an acquireable reference to their ERC20 for a given spender, acquired via `transferFrom()`.
 *         However, all `transfer()` calls incur a "dereference" back to the home chain to natively
 *         transfer the ERC20 to the desired recipient, backed by Superchain Message Passing. As a result,
 *         an ERC20 can be remotely controlled by an account without fungible wrapped representations.
 */
contract ERC20Reference is ERC20 {
    /// @notice the ERC20 token of this remote representation
    IERC20 public erc20;

    /// @notice the chain the ERC20 lives on
    uint256 public homeChainId;

    /// @notice the remote chain that can hold a lock on this ERC20
    uint256 public remoteChainId;

    /// @dev The messenger predeploy to handle message passing
    IL2ToL2CrossDomainMessenger internal _messenger =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice The constructor.
    /// @param _homeChainId The chain the ERC20 lives on
    /// @param _erc20 The ERC20 token this remote representation is based on
    /// @param _remoteChainId The chain this erc20 is controlled by
    constructor(uint256 _homeChainId, IERC20 _erc20, uint256 _remoteChainId) {
        // By asserting the deployer is used, we obtain good safety that
        //  1. This contract was deterministically created based on the constructor args
        //  2. `approve()` & `transfer()` only works on the correctly erc20 address (constructor arg)
        require(msg.sender == PreinstallAddresses.CREATE2_DEPLOYER);

        homeChainId = _homeChainId;
        erc20 = _erc20;
        remoteChainId = _remoteChainId;
    }

    /// @notice Approve a spender on the remote to pull an amount of ERC20Reference
    /// @param _spender The address of the spender on the remote chain
    /// @param _amount The amount to approve
    /// @return success True if the approval was successful
    function approve(address _spender, uint256 _amount) public override returns (bool) {
        require(block.chainid == homeChainId);

        // (1) Escrow the ERC20
        erc20.transferFrom(msg.sender, address(this), _amount);

        // (2) Send a message to approve the spender over the new reference
        bytes memory call = abi.encodeCall(this.handleApproval, (msg.sender, _spender, _amount));
        _messenger.sendMessage(remoteChainId, address(this), call);
        return true;
    }

    /// @notice Handle an approval, creating a reference to the new amount, approved for the spender.
    /// @param _owner The owner of the ERC20Reference
    /// @param _spender The spender of the ERC20Reference
    /// @param _amount The amount to approve
    function handleApproval(address _owner, address _spender, uint256 _amount) external {
        require(block.chainid == remoteChainId);
        require(msg.sender == address(_messenger));

        // (1) Call must have come from the this RemoteERC20
        address sender = _messenger.crossDomainMessageSender();
        require(sender == address(this));

        // (2) Mint the ERC20 to the original owner (re-used _sender argument)
        super._mint(_owner, _amount);

        // (3) Manually set the allowance over the lock for the spender.
        super._approve(_owner, _spender, _amount);
    }

    /// @notice Transfer the approved ERC20Reference to the spender.
    /// @param _from The sender
    /// @param _to The recipient
    /// @param _amount The amount
    /// @return success True if the transfer was successful
    function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
        require(block.chainid == remoteChainId, "Acquirable only on the remote");
        return super.transferFrom(_from, _to, _amount);
    }

    /// @notice Transfer the ERC20Reference. This burns the specified amount of this reference, and natively
    ///         transfers the ERC20 to the recipient on the home chain
    /// @param _to The recipient
    /// @param _amount The amount
    /// @return success True if the transfer was successful
    function transfer(address _to, uint256 _amount) public override returns (bool) {
        if (block.chainid == remoteChainId) {
            // (1) Burn the held reference
            super._burn(msg.sender, _amount);

            // (2) Send a message to transfer the held value
            _messenger.sendMessage(homeChainId, address(this), abi.encodeCall(this.transfer, (_to, _amount)));
            return true;
        } else {
            require(msg.sender == address(_messenger));

            // (1) Call must have come from the this ERC20Reference
            address sender = _messenger.crossDomainMessageSender();
            require(sender == address(this));

            // (2) Unlock the ERC20 to the recipient
            return erc20.transfer(_to, _amount);
        }
    }

    /// @notice Returns the name of the ERC20Reference
    function name() public pure override returns (string memory) {
        return "ERC20Reference";
    }

    /// @notice Returns the symbol of the ERC20Reference
    function symbol() public pure override returns (string memory) {
        return "ERC20Ref";
    }
}
