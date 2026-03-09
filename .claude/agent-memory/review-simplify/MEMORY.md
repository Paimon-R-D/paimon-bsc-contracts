# Review-Simplify Agent Memory

## Project Patterns

### LayerZero Module Structure
- Hub contracts: `src/layerzero/hub/` (CreditManager, CrossChainAssetController, PPTOFTAdapter)
- Satellite contracts: `src/layerzero/satellite/` (PPTOFT, PPTSatellite, LiquidityPool, adapters/RemoteAssetAdapter)
- Interfaces: `src/layerzero/interfaces/` (ICreditManager, ILiquidityPool, IPPTOFT, IPPTOFTAdapter, IPPTSatellite)
- Libraries: `src/layerzero/libraries/` (DeltaLib, LayerZeroErrors, LzOptionsLib)

### Known Duplication Hotspots (confirmed 2026-03-09)
1. **_buildOptions/_buildDefaultOptions/_buildLzReceiveOptions**: Identical in 5 contracts. LzOptionsLib exists but is unused.
2. **Error definitions**: LayerZeroErrors library exists but is never imported. Every contract redeclares its own errors.
3. **OFT core functions**: _debitView, _removeDust, _buildSendMessage, _bytes32ToAddress, quoteSend, send are duplicated between PPTOFT and PPTOFTAdapter. Missing abstract OFTCore base.
4. **Array swap-and-pop**: Duplicated in CreditManager.removeChain and CrossChainAssetController.removeSupportedChain.
5. **Struct definitions**: SendParam, MessagingFee, MessagingReceipt, OFTReceipt duplicated in IPPTOFT and IPPTOFTAdapter.

### Complexity Observations
- Highest complexity function: CreditManager.rebalance (~CC8, 48 lines, 3 nesting levels)
- No function exceeds 50 lines currently
- Magic number 10000 (BPS) used inconsistently; CreditManager has BPS_DENOMINATOR but LiquidityPool/PPTSatellite use literal
