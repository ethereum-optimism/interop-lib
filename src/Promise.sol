// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ICrossL2Inbox, Identifier} from "./interfaces/ICrossL2Inbox.sol";
import {Hashing} from "./libraries/Hashing.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";
import {TransientReentrancyAware} from "./libraries/TransientContext.sol";

contract Promise is TransientReentrancyAware {
    /// @notice a struct to represent a callback to be executed when the return value of
    ///         a sent message is captured.
    struct Callback {
        address target;
        bytes4 selector;
        bytes context;
    }

    /// @dev The L2 to L2 cross domain messenger predeploy to handle message passing
    IL2ToL2CrossDomainMessenger internal messenger =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice a mapping of message hashes to their registered callbacks
    mapping(bytes32 => Callback[]) public callbacks;

    /// @notice the relay identifier that is satisfying the promise
    Identifier internal currentRelayIdentifier;

    /// @notice the context that is being propagated with the promise
    bytes internal currentContext;

    /// @notice a mapping of message sent by this library. To prevent callbacks being registered to messages
    ///         sent directly to the L2ToL2CrossDomainMessenger which does not emit the return value (yet)
    mapping(bytes32 => bool) private sentMessages;

    /// @notice an event emitted when a callback is registered
    event CallbackRegistered(bytes32 messageHash);

    /// @notice an event emitted when all callbacks for a message are dispatched
    event CallbacksCompleted(bytes32 messageHash);

    /// @notice an event emitted when a message is relayed
    event RelayedMessage(bytes32 messageHash, bytes returnData);

    /// @dev Modifier to restrict a function to only be a cross domain callback into this contract
    modifier onlyCrossDomainCallback() {
        require(msg.sender == address(messenger), "Promise: caller not L2ToL2CrossDomainMessenger");
        require(messenger.crossDomainMessageSender() == address(this), "Promise: invalid cross-domain sender");
        _;
    }

    /// @notice send a message to the destination contract capturing the return value. this cannot call
    ///         contracts that rely on the L2ToL2CrossDomainMessenger, such as the SuperchainTokenBridge.
    function sendMessage(uint256 _destination, address _target, bytes calldata _message) external returns (bytes32) {
        uint256 nonce = messenger.messageNonce();
        bytes32 msgHash = messenger.sendMessage(
            _destination, address(this), abi.encodeCall(this.handleMessage, (nonce, _target, _message))
        );
        sentMessages[msgHash] = true;
        return msgHash;
    }

    /// @dev handler to dispatch and emit the return value of a message
    function handleMessage(uint256 _nonce, address _target, bytes calldata _message) external onlyCrossDomainCallback {
        (bool success, bytes memory returnData_) = _target.call(_message);
        require(success, "Promise: target call failed");

        // reconstruct the L2ToL2CrossDomainMessenger message hash
        bytes32 messageHash = Hashing.hashL2toL2CrossDomainMessage({
            _destination: block.chainid,
            _source: messenger.crossDomainMessageSource(),
            _nonce: _nonce,
            _sender: address(this),
            _target: address(this),
            _message: abi.encodeCall(this.handleMessage, (_nonce, _target, _message))
        });

        emit RelayedMessage(messageHash, returnData_);
    }

    /// @notice attach a continuation dependent only on the return value of the remote message
    function then(bytes32 _msgHash, bytes4 _selector) external {
        require(sentMessages[_msgHash], "Promise: message not sent");
        callbacks[_msgHash].push(Callback({target: msg.sender, selector: _selector, context: ""}));
        emit CallbackRegistered(_msgHash);
    }

    /// @notice attach a continuation dependent on the return value and some additional saved context
    function then(bytes32 _msgHash, bytes4 _selector, bytes calldata _context) external {
        require(sentMessages[_msgHash], "Promise: message not sent");
        callbacks[_msgHash].push(Callback({target: msg.sender, selector: _selector, context: _context}));
        emit CallbackRegistered(_msgHash);
    }

    /// @notice invoke continuations present on the completion of a remote message. for now this requires all
    ///         callbacks to be dispatched in a single call. A failing callback will halt the entire process.
    function dispatchCallbacks(Identifier calldata _id, bytes calldata _payload) external payable nonReentrant {
        require(_id.origin == address(this), "Promise: invalid origin");
        ICrossL2Inbox(PredeployAddresses.CROSS_L2_INBOX).validateMessage(_id, keccak256(_payload));

        bytes32 eventSel = abi.decode(_payload[:32], (bytes32));
        require(eventSel == RelayedMessage.selector, "Promise: invalid event");

        currentRelayIdentifier = _id;

        (bytes32 msgHash, bytes memory returnData) = abi.decode(_payload[32:], (bytes32, bytes));
        for (uint256 i = 0; i < callbacks[msgHash].length; i++) {
            Callback memory callback = callbacks[msgHash][i];
            if (callback.context.length > 0) {
                currentContext = callback.context;
            }

            (bool completed,) = callback.target.call(abi.encodePacked(callback.selector, returnData));
            require(completed, "Promise: callback call failed");

            if (callback.context.length > 0) {
                delete currentContext;
            }
        }

        emit CallbacksCompleted(msgHash);

        // storage cleanup
        delete callbacks[msgHash];
        delete sentMessages[msgHash];
        delete currentRelayIdentifier;
    }

    /// @notice get the context that is being propagated with the promise
    function promiseContext() public view returns (bytes memory) {
        return currentContext;
    }

    /// @notice get the relay identifier that is satisfying the promise
    function promiseRelayIdentifier() public view returns (Identifier memory) {
        return currentRelayIdentifier;
    }
}
