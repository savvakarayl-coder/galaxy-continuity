# E2E Test Infra: Galaxy Continuity

## Test Philosophy
- Opaque-box, requirement-driven. No dependency on internal implementation structures.
- Exercising the system via external interfaces: RFC 6455 WebSocket framing, HTTP file transfer endpoints, simulated socket clients, and build commands.
- Methodology: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Combinatorial Testing + Real-World Workload Testing across 4 tiers.

## Feature Inventory
| # | Feature | Source | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---------|--------|:------:|:------:|:------:|:------:|
| 1 | Handshake & Protocol Framing | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 2 | Bidirectional Text Clipboard | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 3 | Bidirectional Image Clipboard | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 4 | Quick Drop File Transfer (Mac -> Phone) | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 5 | Quick Drop File Transfer (Phone -> Mac) | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 6 | Screen Mirroring & Remote Input | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 7 | Continuity Camera & Virtual Webcam | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 8 | Notification Sync & Interactive Reply | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 9 | Peer Discovery (mDNS, BLE, Wi-Fi Direct) | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 10 | Android APK Build & GitHub Release | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ | ✓ |

## Test Architecture
- **Location**: `tests/e2e/` at project root.
- **Test Runner**: Python 3 standard library (`tests/e2e/runner.py`) executing independently with zero external pip dependencies.
- **Pass/Fail Semantics**: Returns exit code 0 when 100% of tests pass; non-zero if any test fails. Output includes structured test case counts and timings.
- **Directory Layout**:
  ```
  tests/e2e/
  ├── runner.py              # Master test runner
  ├── harness.py             # Mock socket / HTTP / BLE client harness
  ├── test_tier1_features.py # Tier 1: Equivalence class representative tests
  ├── test_tier2_boundary.py # Tier 2: Boundary value, edge case, and error tests
  ├── test_tier3_pairwise.py # Tier 3: Cross-feature interaction tests
  └── test_tier4_workload.py # Tier 4: End-to-end real-world user scenarios
  ```

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| 1 | Workday Workflow: Clipboard sync of code snippets + image diagrams while receiving phone notifications and replying inline | F2, F3, F8 | Medium |
| 2 | Large Media Transfer: High-speed Quick Drop file transfer while screen mirroring video stream simultaneously | F4, F5, F6 | High |
| 3 | Continuity Video Call: Streaming phone camera feed to macOS virtual webcam while maintaining clipboard sync and battery updates | F7, F2 | High |
| 4 | Offline Reconnection: Peer discovery transitioning from mDNS to offline BLE/Wi-Fi Direct with session resumption | F9, F1 | High |
| 5 | Full Production Pipeline: Clean APK build verification, mock release packaging, and end-to-end continuity session verification | F10, F1-F9 | High |

## Coverage Thresholds
- N = 10 major features
- Tier 1: ≥5 per feature (50 test cases)
- Tier 2: ≥5 per feature (50 boundary/corner cases)
- Tier 3: pairwise coverage of major feature interactions (≥10 tests)
- Tier 4: realistic application scenarios (≥5 tests)
- **Total minimum**: ≥115 test cases
