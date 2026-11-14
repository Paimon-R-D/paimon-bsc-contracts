# Review-Errors Agent Memory

## Project: paimon-bsc-contracts

### Key Patterns Observed

1. **LayerZero cross-chain contracts** in `src/layerzero/` - Hub (BSC) + Satellite (remote chains) architecture
2. **Common silent failure pattern**: `if (balance >= fee) { send } else { /* nothing */ }` - appears in RemoteAssetAdapter for confirmations
3. **Encoding inconsistency**: Some contracts use `abi.encode(msgType, data)` while others use `abi.encodePacked(msgType, abi.encode(data))` for cross-chain payloads. The `encodePacked` pattern is correct for the `bytes1(payload[0])` extraction pattern.
4. **Contracts use SafeERC20** consistently for token transfers - good practice
5. **Placeholder implementations** exist in RemoteAssetAdapter._handleDeploy and PPTOFTAdapter._requestRedemption - flag these as P1 in reviews
6. **LiquidityPool has no LP share tracking** - addLiquidity/removeLiquidity are both public with no accounting

### Review Focus Areas for This Codebase
- Cross-chain message encoding/decoding consistency
- Silent failure in gas-dependent confirmation sends
- Optimistic state updates without rollback mechanisms
- Placeholder code that could reach production
- ReentrancyGuard consistency across _lzReceive handlers
