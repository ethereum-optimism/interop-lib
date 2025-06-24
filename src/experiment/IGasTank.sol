// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Identifier} from "../interfaces/IIdentifier.sol";
import {IL2ToL2CrossDomainMessenger} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";

interface IGasTank {
    // Structs
    struct Withdrawal {
        uint256 timestamp;
        uint256 amount;
    }

    // Events
    event AuthorizedClaim(address indexed gasProvider, bytes32 indexed messageHash);
    event Claimed(
        bytes32 indexed originMsgHash,
        address indexed relayer,
        address indexed gasProvider,
        address claimer,
        uint256 relayCost,
        uint256 claimCost
    );
    event Deposit(address indexed depositor, uint256 amount);
    event RelayedMessageGasReceipt(
        bytes32 indexed messageHash, address indexed relayer, uint256 gasCost, bytes32[] nestedMessageHashes
    );
    event WithdrawalInitiated(address indexed from, uint256 amount);
    event WithdrawalFinalized(address indexed from, address indexed to, uint256 amount);

    // Errors
    error MaxDepositExceeded();
    error InvalidOrigin();
    error InvalidPayload();
    error InsufficientBalance();
    error AlreadyClaimed();
    error MessageNotAuthorized();
    error WithdrawPending();
    error InvalidLength();

    // Constants
    function MAX_DEPOSIT() external pure returns (uint256);
    function WITHDRAWAL_DELAY() external pure returns (uint256);
    function MESSENGER() external pure returns (IL2ToL2CrossDomainMessenger);

    // State Variables
    function balanceOf(address) external view returns (uint256);
    function withdrawals(address) external view returns (uint256 timestamp, uint256 amount);
    function claimed(bytes32) external view returns (bool);
    function authorizedMessages(address, bytes32) external view returns (bool);

    // Functions
    function deposit(address _to) external payable;
    function initiateWithdrawal(uint256 _amount) external;
    function finalizeWithdrawal(address _to) external;
    function authorizeClaim(bytes32 _messageHash) external;
    function relayMessage(
        Identifier calldata _id,
        bytes calldata _sentMessage
    )
        external
        returns (uint256 gasCost_, bytes32[] memory nestedMessageHashes_);
    function claim(Identifier calldata _id, address _gasProvider, bytes calldata _payload) external;
    function decodeGasReceiptPayload(bytes calldata _payload)
        external
        pure
        returns (
            bytes32 originMessageHash_,
            address relayer_,
            uint256 relayCost_,
            bytes32[] memory destinationMessageHashes_
        );
    function claimOverhead(uint256 _numHashes, uint256 _baseFee) external pure returns (uint256);
}
