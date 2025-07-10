// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

// Interfaces
import {ICrossL2Inbox} from "../interfaces/ICrossL2Inbox.sol";
import {IGasTank} from "./IGasTank.sol";
import {IL2ToL2CrossDomainMessenger} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";
import {Identifier} from "../interfaces/IIdentifier.sol";
import {IGasPriceOracle} from "../interfaces/IGasPriceOracle.sol";

// Libraries
import {Encoding} from "../libraries/Encoding.sol";
import {Hashing} from "../libraries/Hashing.sol";
import {PredeployAddresses} from "../libraries/PredeployAddresses.sol";
import {SafeSend} from "../universal/SafeSend.sol";

/// @title GasTank
/// @notice Allows users to deposit native tokens to compensate relayers for executing cross chain transactions
contract GasTank is IGasTank {
    using Encoding for uint256;

    /// @notice The delay before a withdrawal can be finalized
    uint256 public constant WITHDRAWAL_DELAY = 7 days;

    /// @notice The cross domain messenger
    IL2ToL2CrossDomainMessenger public constant MESSENGER =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice The gas price oracle for L1 cost calculations
    IGasPriceOracle public constant GAS_PRICE_ORACLE = IGasPriceOracle(PredeployAddresses.GAS_PRICE_ORACLE);

    /// @notice The balance of each gas provider
    mapping(address gasProvider => uint256 balance) public balanceOf;

    /// @notice The current withdrawal of each gas provider
    mapping(address gasProvider => Withdrawal) public withdrawals;

    /// @notice The authorized messages for claiming
    mapping(address gasProvider => mapping(bytes32 messageHash => bool authorized)) public authorizedMessages;

    /// @notice The claimed messages
    mapping(bytes32 messageHash => bool claimed) public claimed;

    /// @notice Deposits funds into the gas tank, from which the relayer can claim the repayment after relaying
    /// @param _to The address to deposit the funds to
    function deposit(address _to) external payable {
        balanceOf[_to] += msg.value;

        emit Deposit(_to, msg.value);
    }

    /// @notice Initiates a withdrawal of funds from the gas tank
    /// @param _amount The amount of funds to initiate a withdrawal for
    function initiateWithdrawal(uint256 _amount) external {
        withdrawals[msg.sender] = Withdrawal({timestamp: block.timestamp, amount: _amount});

        emit WithdrawalInitiated(msg.sender, _amount);
    }

    /// @notice Finalizes a withdrawal of funds from the gas tank
    /// @param _to The address to finalize the withdrawal to
    function finalizeWithdrawal(address _to) external {
        Withdrawal memory withdrawal = withdrawals[msg.sender];

        if (block.timestamp < withdrawal.timestamp + WITHDRAWAL_DELAY) revert WithdrawPending();

        uint256 amount = _min(balanceOf[msg.sender], withdrawal.amount);

        balanceOf[msg.sender] -= amount;

        delete withdrawals[msg.sender];

        new SafeSend{value: amount}(payable(_to));

        emit WithdrawalFinalized(msg.sender, _to, amount);
    }

    /// @notice Authorizes a message to be claimed by the relayer
    /// @param _messageHashes The hashes of the messages to authorize
    function authorizeClaim(bytes32[] calldata _messageHashes) external {
        uint256 messageHashesLength = _messageHashes.length;

        for (uint256 i; i < messageHashesLength; i++) {
            authorizedMessages[msg.sender][_messageHashes[i]] = true;
        }

        emit AuthorizedClaims(msg.sender, _messageHashes);
    }

    /// @notice Relays a message to the destination chain
    /// @param _id The identifier of the message
    /// @param _sentMessage The sent message event payload
    /// @param _gasProvider The address of the gas provider
    /// @param _gasProviderChainID The chain ID of the gas provider
    function relayMessage(
        Identifier calldata _id,
        bytes calldata _sentMessage,
        address _gasProvider,
        uint256 _gasProviderChainID
    ) external returns (uint256 relayCost_, bytes32[] memory nestedMessageHashes_) {
        uint256 initialGas = gasleft();

        bytes32 messageHash = _getMessageHash(_id.chainId, _sentMessage);

        uint240 nonceBefore = _getMessengerNonce();

        MESSENGER.relayMessage(_id, _sentMessage);

        // Get the amount of nested messages by getting the nonce increment
        uint256 nonceDelta = _getMessengerNonce() - nonceBefore;

        nestedMessageHashes_ = new bytes32[](nonceDelta);

        for (uint256 i; i < nonceDelta; i++) {
            nestedMessageHashes_[i] = MESSENGER.sentMessages(nonceBefore + i);
        }

        // Get the gas used
        relayCost_ = _cost(initialGas - gasleft(), block.basefee) + _relayOverhead(nestedMessageHashes_.length)
            + GAS_PRICE_ORACLE.getL1Fee(msg.data);

        emit RelayedMessageGasReceipt(
            messageHash, msg.sender, _gasProvider, _gasProviderChainID, relayCost_, nestedMessageHashes_
        );
    }

    /// @notice Claims repayment for a relayed message
    /// @param _id The identifier of the message
    /// @param _payload The payload of the message
    function claim(Identifier calldata _id, bytes calldata _payload) external {
        // Ensure the origin is a gas tank deployed with the same address on the destination chain
        if (_id.origin != address(this)) revert InvalidOrigin();

        // Validate the message
        ICrossL2Inbox(PredeployAddresses.CROSS_L2_INBOX).validateMessage(_id, keccak256(_payload));

        (
            bytes32 messageHash,
            address relayer,
            address gasProvider,
            uint256 gasProviderChainID,
            uint256 relayCost,
            bytes32[] memory nestedMessageHashes
        ) = decodeGasReceiptPayload(_payload);

        if (gasProviderChainID != block.chainid) revert InvalidChainID();

        if (!authorizedMessages[gasProvider][messageHash]) revert MessageNotAuthorized();

        if (claimed[messageHash]) revert AlreadyClaimed();

        uint256 nestedMessageHashesLength = nestedMessageHashes.length;

        if (nestedMessageHashesLength != 0) {
            for (uint256 i; i < nestedMessageHashesLength; i++) {
                authorizedMessages[gasProvider][nestedMessageHashes[i]] = true;
            }
            emit AuthorizedClaims(gasProvider, nestedMessageHashes);
        }

        if (balanceOf[gasProvider] < relayCost) revert InsufficientBalance();

        uint256 claimCost = _min(
            balanceOf[gasProvider],
            _claimOverhead(nestedMessageHashesLength, block.basefee) + GAS_PRICE_ORACLE.getL1Fee(msg.data)
        );

        balanceOf[gasProvider] -= relayCost + claimCost;

        claimed[messageHash] = true;

        delete authorizedMessages[gasProvider][messageHash];

        new SafeSend{value: relayCost}(payable(relayer));

        new SafeSend{value: claimCost}(payable(msg.sender));

        emit Claimed(messageHash, relayer, gasProvider, msg.sender, relayCost, claimCost);
    }

    /// @notice Decodes the payload of the RelayedMessageGasReceipt event
    /// @param _payload The payload of the event
    /// @return messageHash_ The hash of the relayed message
    /// @return relayer_ The address of the relayer
    /// @return gasProvider_ The address of the gas provider
    /// @return gasProviderChainID_ The chain ID of the gas provider
    /// @return relayCost_ The amount of native tokens expended on the relay
    /// @return nestedMessageHashes_ The hashes of the destination messages
    function decodeGasReceiptPayload(bytes calldata _payload)
        public
        pure
        returns (
            bytes32 messageHash_,
            address relayer_,
            address gasProvider_,
            uint256 gasProviderChainID_,
            uint256 relayCost_,
            bytes32[] memory nestedMessageHashes_
        )
    {
        if (bytes32(_payload[:32]) != RelayedMessageGasReceipt.selector) revert InvalidPayload();

        // Decode Topics
        (messageHash_, relayer_) = abi.decode(_payload[32:96], (bytes32, address));

        // Decode Data
        (gasProvider_, gasProviderChainID_, relayCost_, nestedMessageHashes_) =
            abi.decode(_payload[96:], (address, uint256, uint256, bytes32[]));
    }

    /// @notice Simulates the overhead of a claim transaction
    /// @param _numHashes The number of destination hashes relayed
    /// @param _baseFee The base fee of the block
    /// @return overhead_ The overhead cost of the claim transaction in wei
    function simulateClaimOverhead(uint256 _numHashes, uint256 _baseFee) external pure returns (uint256 overhead_) {
        overhead_ = _claimOverhead(_numHashes, _baseFee);
    }

    /// @notice Calculates the overhead of a claim
    /// @param _numHashes The number of destination hashes relayed
    /// @param _baseFee The base fee of the block
    /// @return overhead_ The overhead cost of the claim transaction in wei
    /// @dev Gas calculations based on config: optimizer=true, optimizer_runs=999999, evm_version="cancun"
    function _claimOverhead(uint256 _numHashes, uint256 _baseFee) internal pure returns (uint256 overhead_) {
        uint256 dynamicCost;
        uint256 fixedCost;

        if (_numHashes == 0) {
            fixedCost = 300_450;
        } else if (_numHashes == 1) {
            fixedCost = 335_500;
        } else if (_numHashes == 2) {
            fixedCost = 370_300;
        } else {
            fixedCost = 301_000;
            dynamicCost = 34_822 * _numHashes;
            dynamicCost += (_numHashes * _numHashes) >> 11;
        }

        // Calculate L2 and L1 costs separately
        overhead_ = _cost(fixedCost + dynamicCost, _baseFee);
    }

    /// @notice Calculates the overhead to emit RelayedMessageGasReceipt
    /// @param _numHashes The number of destination hashes relayed
    /// @return overhead_ The gas cost to emit the event in wei
    /// @dev Gas calculations based on config: optimizer=true, optimizer_runs=999999, evm_version="cancun"
    function _relayOverhead(uint256 _numHashes) internal view returns (uint256 overhead_) {
        uint256 dynamicCost = 417 * _numHashes;
        uint256 fixedCost = 35_480;
        overhead_ = _cost(fixedCost + dynamicCost, block.basefee);
    }

    /// @notice Calculates the cost of gas used in wei
    /// @param _gasUsed The amount of gas to calculate the cost for
    /// @param _baseFee The base fee of the block
    /// @return cost_ The cost in wei
    function _cost(uint256 _gasUsed, uint256 _baseFee) internal pure returns (uint256 cost_) {
        cost_ = _baseFee * _gasUsed;
    }

    /// @notice Calculates the minimum of two values
    /// @param _a The first value
    /// @param _b The second value
    /// @return min_ The minimum of the two values
    function _min(uint256 _a, uint256 _b) internal pure returns (uint256 min_) {
        min_ = _a < _b ? _a : _b;
    }

    /// @notice Calculates the hash of a message
    /// @param _source The source chain ID
    /// @param _sentMessage The sent message
    /// @return messageHash_ The hash of the message
    function _getMessageHash(uint256 _source, bytes calldata _sentMessage)
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
