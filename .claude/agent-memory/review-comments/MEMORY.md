# Review Comments Agent Memory

## Project: paimon-bsc-contracts (LayerZero cross-chain bridge)

### Common Comment Anti-Patterns Found
- "simplified" / "In production, this would..." / "placeholder" language in RemoteAssetAdapter and PPTOFTAdapter
- Stub implementations with aspirational comments (e.g., _calculateYield always returns 0)
- Missing NatSpec on public constants in PPTSatellite
- Encoding format comments (abi.encode vs abi.encodePacked) that don't clearly state which format the counterparty uses

### LayerZero v2 Notes
- BSC Mainnet EID in LZ v2 is 30102, not 102 (v1 value). Watch for stale EID references.
- Options encoding uses raw uint16(3) format without OptionsBuilder header -- verify compatibility.
- Message encoding: some contracts use abi.encode (CreditManager sends), others use abi.encodePacked (PPTSatellite, RemoteAssetAdapter). Mismatches between sender/receiver encoding can cause silent decoding failures.

### Key Files for Comment Review
- `src/layerzero/satellite/adapters/RemoteAssetAdapter.sol` - Most stub comments
- `src/layerzero/hub/PPTOFTAdapter.sol` - _requestRedemption stub
- `src/layerzero/hub/CreditManager.sol` - Encoding mismatch comments
