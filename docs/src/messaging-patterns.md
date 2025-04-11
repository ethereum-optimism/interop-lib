# Messaging Patterns

This doc contains advanced patterns for constructing and handling cross chain messages.

## Dependent Messages

When handling dependent cross chain messages, proper sequencing is crucial. For example, you may want to bridge an ERC20 to another chain and then perform an action only after the ERC20 has been successfully bridged. In order to do this, you need to make sure that the cross chain messages are relayed in the correct order. This section describes the various patterns for handling dependent messages.

### CrossDomainMessageLib#requireMessageSuccess

The `CrossDomainMessageLib` provides a `requireMessageSuccess` function to enforce correct message sequencing:

```solidity
function requireMessageSuccess(bytes32 msgHash) internal view {
    if (!IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER).successfulMessages(msgHash)) {
        revert RequiredMessageNotSuccessful(msgHash);
    }
}
```

When this check fails, it throws a `RequiredMessageNotSuccessful(bytes32)` error. This error can be handled in two ways:

- **Manual Relaying**: Messages can be manually relayed in the correct order
- **Automated Relaying**: Relayers can:
   1. Parse the required message hash from the error
   2. Wait for the required message to be relayed
   3. Automatically relay the messages that depend on the required message

The auto-relayer built into [supersim](https://github.com/ethereum-optimism/supersim) has this functionality built in, so if you use the `requireMessageSuccess` function your dependent messages will be relayed properly.

Here is an example of how to use this pattern (referenced from the [superchain-starter-xchain-eth-multitransfer](https://github.com/ethereum-optimism/superchain-starter-xchain-eth-multitransfer/blob/main/contracts/src/CrossChainETHMultitransfer.sol) example):

```solidity
 function send(uint256 _destinationChainId, Send[] calldata _sends) public payable returns (bytes32) {
        uint256 totalAmount;
        for (uint256 i; i < _sends.length; i++) {
            totalAmount += _sends[i].amount;
        }

        if (msg.value != totalAmount) revert IncorrectValue();

        bytes32 sendEthMsgHash = superchainEthBridge.sendETH{value: totalAmount}(address(this), _destinationChainId);

        return l2ToL2CrossDomainMessenger.sendMessage(
            _destinationChainId, address(this), abi.encodeCall(this.relay, (sendEthMsgHash, _sends))
        );
    }

    function relay(bytes32 _sendEthMsgHash, Send[] calldata _sends) public {
        CrossDomainMessageLib.requireCrossDomainCallback();
        // CrossDomainMessageLib.requireMessageSuccess uses a special error signature that the
        // auto-relayer performs special handling on. The auto-relayer parses the _sendEthMsgHash
        // and waits for the _sendEthMsgHash to be relayed before relaying this message.
        CrossDomainMessageLib.requireMessageSuccess(_sendEthMsgHash);

        for (uint256 i; i < _sends.length; i++) {
            address to = _sends[i].to;
            // use .call for example purpose, but not recommended in production.
            (bool success,) = to.call{value: _sends[i].amount}("");
            require(success, "ETH transfer failed");
        }
    }

```

Other examples:
- [cross chain flash loan](https://github.com/ethereum-optimism/superchain-starter-xchain-flash-loan-example/blob/8de92ae1e17ae24672cc32c03c88f2edd4121703/contracts/src/CrosschainFlashLoanBridge.sol#L95)

### `superchain-async` Library (**Experimental**)

[Repo](https://github.com/ben-chain/superchain-async/tree/main)

The `superchain-async` library provides an abstraction for asynchronous function calls across interoperating L2s. It introduces an async/promise pattern to handle cross-chain interactions, compatible with vanilla Solidity syntax. This library is still under development and is not yet ready for use in production. We are sharing it here for early feedback and contributions/improvements are welcome.