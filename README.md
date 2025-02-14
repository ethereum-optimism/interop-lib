# interop-lib

Subset of [interoperability](https://specs.optimism.io/interop/overview.html) related contract interfaces / libraries from the [Optimism monorepo](https://github.com/ethereum-optimism/optimism/tree/develop/packages/contracts-bedrock)

## Installation

To install with [**Foundry**](https://github.com/foundry-rs/foundry):

```bash
forge install ethereum-optimism/interop-lib
```

### Remappings

#### foundry.toml

```toml
remappings = [
  "@interop-lib/=lib/interop-lib/src/"
]
```

#### remappings.txt (VSCode)

```txt
@interop-lib/=lib/interop-lib/src/
```

### Importing

```solidity
import {IERC7802} from "@interop-lib/interfaces/IL2ToL2CrossDomainMessenger.sol";
import {PredeployAddresses} from "@interop-lib/libraries/PredeployAddresses.sol";
```

## Overview

### Interfaces

- [ICrossL2Inbox.sol](src/interfaces/ICrossL2Inbox.sol)
- [IERC7802.sol](src/interfaces/IERC7802.sol)
- [IETHLiquidity.sol](src/interfaces/IETHLiquidity.sol)
- [IL2ToL2CrossDomainMessenger.sol](src/interfaces/IL2ToL2CrossDomainMessenger.sol)
- [ISemver.sol](src/interfaces/ISemver.sol)
- [ISuperchainTokenBridge.sol](src/interfaces/ISuperchainTokenBridge.sol)
- [ISuperchainWETH.sol](src/interfaces/ISuperchainWETH.sol)
- [IWETH98.sol](src/interfaces/IWETH98.sol)

### Libraries

- [CrossDomainMessageLib.sol](src/libraries/CrossDomainMessageLib.sol)
- [PredeployAddresses.sol](src/libraries/PredeployAddresses.sol)

### Contracts

- [SuperchainERC20.sol](src/SuperchainERC20.sol)
