# Review-Code Agent Memory

## Project: paimon-bsc-contracts

### Recurring Patterns (confirmed 2026-03-09)

- **LayerZero V2 options encoding**: All contracts manually encode LZ options as `abi.encodePacked(uint16(3), gasLimit, uint128(0))`. This likely uses incorrect format (missing worker ID header). LzOptionsLib exists but is unused. Check against official OptionsBuilder.
- **Payload encoding mismatch**: Some contracts use `abi.encode(msgType, data)` (32-byte aligned) while others use `abi.encodePacked(msgType) + abi.encode(data)` (1-byte prefix). Receivers inconsistently parse with either `abi.decode(payload, ...)` or `bytes1(payload[0]) + abi.decode(payload[1:], ...)`. This is a critical cross-chain interop bug.
- **Orphan libraries**: LayerZeroErrors.sol and LzOptionsLib.sol are defined but imported by zero contracts. Each contract duplicates their definitions locally.
- **Optimistic accounting**: CrossChainAssetController decrements tracking before remote confirmation. No rollback mechanism.
- **LiquidityPool access control gap**: removeLiquidity has no access control -- anyone can drain.
- **Solidity version**: ^0.8.24, OpenZeppelin 5.x, LayerZero V2 OApp pattern.

### File Structure
- Hub contracts: `src/layerzero/hub/` (CreditManager, CrossChainAssetController, PPTOFTAdapter)
- Satellite contracts: `src/layerzero/satellite/` (PPTOFT, PPTSatellite, LiquidityPool, RemoteAssetAdapter)
- Interfaces: `src/layerzero/interfaces/`
- Libraries: `src/layerzero/libraries/`
