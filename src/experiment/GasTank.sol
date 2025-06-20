// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

// Interfaces
import {ICrossL2Inbox} from "../interfaces/ICrossL2Inbox.sol";
import {IGasTank} from "./IGasTank.sol";
import {IL2ToL2CrossDomainMessenger} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";
import {Identifier} from "../interfaces/IIdentifier.sol";

// Libraries
import {Encoding} from "../libraries/Encoding.sol";
import {Hashing} from "../libraries/Hashing.sol";
import {PredeployAddresses} from "../libraries/PredeployAddresses.sol";
import {SafeSend} from "../universal/SafeSend.sol";

/// @title GasTank
/// @notice Allows users to deposit native tokens to compensate relayers for executing cross chain transactions
contract GasTank is IGasTank {
    using Encoding for uint256;

    /// @notice The maximum amount of funds that can be deposited into the gas tank
    uint256 public constant MAX_DEPOSIT = 0.01 ether;

    /// @notice The delay before a withdrawal can be finalized
    uint256 public constant WITHDRAWAL_DELAY = 7 days;

    /// @notice The cross domain messenger
    IL2ToL2CrossDomainMessenger public constant MESSENGER =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice The balance of each gas provider
    mapping(address gasProvider => uint256 balance) public balanceOf;

    /// @notice The current withdrawal of each gas provider
    mapping(address gasProvider => Withdrawal) public withdrawals;

    /// @notice The authorized messages for claiming
    mapping(address gasProvider => mapping(bytes32 msgHash => bool authorized)) public authorizedMessages;

    /// @notice The claimed messages
    mapping(bytes32 rootMsgHash => bool claimed) public claimed;

    /// @notice Deposits funds into the gas tank, from which the relayer can claim the repayment after relaying
    /// @param _to The address to deposit the funds to
    function deposit(address _to) external payable {
        uint256 newBalance = balanceOf[_to] + msg.value;

        if (newBalance > MAX_DEPOSIT) revert MaxDepositExceeded();

        balanceOf[_to] = newBalance;
        emit Deposit(_to, msg.value);
    }

    /// @notice Initiates a withdrawal of funds from the gas tank
    /// @param _amount The amount of funds to initiate a withdrawal for
    function initiateWithdrawal(uint256 _amount) external {
        withdrawals[msg.sender] = Withdrawal({ timestamp: block.timestamp, amount: _amount });

        emit WithdrawalInitiated(msg.sender, _amount);
    }

    /// @notice Finalizes a withdrawal of funds from the gas tank
    /// @param _to The address to finalize the withdrawal to
    function finalizeWithdrawal(address _to) external {
        Withdrawal memory withdrawal = withdrawals[msg.sender];

        if (block.timestamp < withdrawal.timestamp + WITHDRAWAL_DELAY) revert WithdrawPending();

        uint256 amount = balanceOf[msg.sender] < withdrawal.amount ? balanceOf[msg.sender] : withdrawal.amount;
        balanceOf[msg.sender] -= amount;

        delete withdrawals[msg.sender];

        new SafeSend{ value: amount }(payable(_to));

        emit WithdrawalFinalized(msg.sender, _to, amount);
    }

    /// @notice Authorizes a message to be claimed by the relayer
    /// @param _messageHash The hash of the message to authorize
    function authorizeClaim(bytes32 _messageHash) external {
        authorizedMessages[msg.sender][_messageHash] = true;

        emit AuthorizedClaim(msg.sender, _messageHash);
    }

    /// @notice Relays a message to the destination chain
    /// @param _id The identifier of the message
    /// @param _sentMessage The sent message event payload
    function relayMessage(
        Identifier calldata _id,
        bytes calldata _sentMessage
    )
        external
        returns (uint256 gasCost_, bytes32[] memory nestedMessageHashes_)
    {
        uint256 initialGas = gasleft();

        bytes32 messageHash = _getMessageHash(_id.chainId, _sentMessage);

        uint240 nonceBefore = _getMessengerNonce();

        MESSENGER.relayMessage(_id, _sentMessage);

        // Get the amount of nested messages by getting the nonce increment
        uint256 nonceDelta = _getMessengerNonce() - nonceBefore;

        nestedMessageHashes_ = new bytes32[](nonceDelta);

        for (uint256 i; i < nonceDelta; i++) {
            nestedMessageHashes_[i] = MESSENGER.sentMessages(nonceBefore + (i + 1));
        }

        // Get the gas used
        gasCost_ = _cost(initialGas - gasleft()) + _gasReceiptEventOverhead(nestedMessageHashes_.length);

        // Emit the event with the relationship between the origin message and the destination messages
        emit RelayedMessageGasReceipt(messageHash, msg.sender, gasCost_, nestedMessageHashes_);
    }

    /// @notice Claims repayment for a relayed message
    /// @param _id The identifier of the message
    /// @param _gasProvider The address of the gas provider
    /// @param _payload The payload of the message
    function claim(Identifier calldata _id, address _gasProvider, bytes calldata _payload) external {
        // Ensure the origin is a gas tank deployed with the same address on the destination chain
        if (_id.origin != address(this)) revert InvalidOrigin();

        // Validate the message
        ICrossL2Inbox(PredeployAddresses.CROSS_L2_INBOX).validateMessage(_id, keccak256(_payload));

        (bytes32 originMessageHash, address relayer, uint256 relayCost, bytes32[] memory destinationMessageHashes) =
            decodeGasReceiptPayload(_payload);

        if (!authorizedMessages[_gasProvider][originMessageHash]) revert MessageNotAuthorized();

        if (claimed[originMessageHash]) revert AlreadyClaimed();

        uint256 destinationMessageHashesLength = destinationMessageHashes.length;

        // Authorize nested messages by the same gas provider
        for (uint256 i; i < destinationMessageHashesLength; i++) {
            authorizedMessages[_gasProvider][destinationMessageHashes[i]] = true;
        }

        // Compute total cost (adding the overhead of this claim)
        uint256 cost = relayCost + claimOverhead(destinationMessageHashesLength);

        if (balanceOf[_gasProvider] < cost) revert InsufficientBalance();

        balanceOf[_gasProvider] -= cost;

        claimed[originMessageHash] = true;

        new SafeSend{ value: cost }(payable(relayer));

        emit Claimed(originMessageHash, relayer, _gasProvider, cost);
    }

    /// @notice Decodes the payload of the RelayedMessageGasReceipt event
    /// @param _payload The payload of the event
    /// @return originMessageHash_ The hash of the relayed message
    /// @return relayer_ The address of the relayer
    /// @return relayCost_ The amount of native tokens expended on the relay
    /// @return destinationMessageHashes_ The hashes of the destination messages
    function decodeGasReceiptPayload(bytes calldata _payload)
        public
        pure
        returns (
            bytes32 originMessageHash_,
            address relayer_,
            uint256 relayCost_,
            bytes32[] memory destinationMessageHashes_
        )
    {
        if (bytes32(_payload[:32]) != RelayedMessageGasReceipt.selector) revert InvalidPayload();

        // Decode Topics
        (originMessageHash_, relayer_, relayCost_) = abi.decode(_payload[32:128], (bytes32, address, uint256));

        // Decode Data
        destinationMessageHashes_ = abi.decode(_payload[128:], (bytes32[]));
    }

    /// @notice Calculates the overhead of a claim
    /// @param _numHashes The number of destination hashes relayed
    /// @return overhead_ The overhead cost of the claim transaction in wei
    function claimOverhead(uint256 _numHashes) public view returns (uint256 overhead_) {
        overhead_ = _cost(125_000 + _numHashes * 23_000);
    }

    /// @notice Calculates the overhead to emit RelayedMessageGasReceipt
    /// @param _numHashes The number of destination hashes relayed
    /// @return overhead_ The gas cost to emit the event in wei
    function _gasReceiptEventOverhead(uint256 _numHashes) internal view returns (uint256 overhead_) {
        overhead_ = _cost(3_000 + _numHashes * 300);
    }

    /// @notice Calculates the cost of gas used in wei
    /// @param _gasUsed The amount of gas to calculate the cost for
    /// @return cost_ The cost in wei
    function _cost(uint256 _gasUsed) internal view returns (uint256 cost_) {
        cost_ = block.basefee * _gasUsed;
    }

    /// @notice Calculates the hash of a message
    /// @param _source The source chain ID
    /// @param _sentMessage The sent message
    /// @return messageHash_ The hash of the message
    function _getMessageHash(
        uint256 _source,
        bytes calldata _sentMessage
    )
        internal
        pure
        returns (bytes32 messageHash_)
    {
        // Decode Topics
        (uint256 destination, address target, uint256 nonce) =
            abi.decode(_sentMessage[32:128], (uint256, address, uint256));

        // Decode Data
        (address sender, bytes memory message) = abi.decode(_sentMessage[128:], (address, bytes));

        // Get the current message hash
        messageHash_ = Hashing.hashL2toL2CrossDomainMessage(destination, _source, nonce, sender, target, message);
    }

    /// @notice Gets the current nonce of the messenger
    /// @return nonce_ The current nonce
    function _getMessengerNonce() internal view returns (uint240 nonce_) {
        (nonce_,) = MESSENGER.messageNonce().decodeVersionedNonce();
    }
}