# Review Coordinator Memory

## Deduplication Patterns

### Cross-Agent Overlap Hotspots (paimon-bsc-contracts)
- **RemoteAssetAdapter silent drops**: review-code and review-errors both flag this, but under different categories (security vs error-handling), so they do NOT merge by strict rules
- **Payload encoding mismatch**: review-code, review-errors, review-comments, review-types all flag abi.encode vs abi.encodePacked issues from different angles (security, error-handling, comments, type-design). Categories differ so they remain separate findings
- **Unused shared libraries**: review-code, review-simplify, review-types all flag LzOptionsLib/LayerZeroErrors/DeltaLib orphan pattern
- **LiquidityPool access control**: review-code (security P1), review-types (type-design P3), review-errors (error-handling via PPTSatellite) -- 3 agents, 0 strict duplicates due to category differences

### Strict Dedup Rule
Two findings merge ONLY if ALL THREE match: same file, line within +-3, same category. In practice this means dedup rate is low (~1-2%) when agents use different category taxonomies. The most common actual merge is review-code + review-errors on the same security-category finding.

### Common Finding Clusters in LayerZero Cross-Chain Contracts
1. Encoding consistency (abi.encode vs abi.encodePacked) -- appears across 4+ agents
2. Silent failure patterns -- review-code and review-errors overlap heavily
3. Orphan/dead library code -- review-code, review-types, review-simplify converge
4. Placeholder/stub implementations -- review-comments and review-errors overlap
5. Interface-implementation divergence -- review-types and review-simplify overlap

## Session Stats
- 2026-03-09 iter1: 68 raw -> 67 deduped (1 merge: RC-004+ERR-007, same file/line/category=security)
