# UI Cleanup and File Convenience Implementation Plan

> Execute inline in the existing isolated worktree with test-driven development and verification-before-completion. The user approved optimization and text cleanup first, followed by the three recommended features.

Goal: Reduce avoidable status/list work and routine explanations, then add file search/type filters, capacity preflight, and completion/interruption notifications.

Architecture: Aggregate automatic-upload status in the ledger actor in one pass; publish only changed status values. Keep file safety behavior while adding the approved convenience features.

Tech Stack: Swift 5, SwiftUI, Combine, XCTest, iOS 17+, existing macOS GitHub Actions.

## Constraints

- Keep bundle ID com.hejong2byte.simplecameraautosender, existing settings, ledgers and originals.
- Optimization does not alter ZIP decoding, USB writes, hashes, overwrite approvals or deletion decisions.
- Keep progress, errors, recovery buttons, accessibility hints and necessary setup instructions.
- Do not change Windows or send real user files/messages during verification.

## 1. Optimize and remove redundant copy

Files: App/Ledger/UploadLedger.swift, App/UI/ContentViewModel.swift, App/UI/ContentView.swift, App/UI/TextTransferView.swift, App/UI/USBReceiverView.swift; corresponding XCTest and UI coverage.

- [ ] Add a real-ledger refresh test covering every asset state, stale failure removal and unchanged persisted records.
- [ ] After initial refresh, subscribe to model.objectWillChange, repeat refresh, and assert zero emissions. Mutate the ledger and assert new values still publish.
- [ ] Assert idle automatic status has no explanatory subtitle and routine screens omit repetitive help without losing error/recovery/deletion controls.
- [ ] Run focused native tests against unchanged production code and record actual failing assertions.
- [ ] Add UploadLedger.statusSummary() returning baseline, queued/uploaded/failed counts and failure categories from one unsorted snapshot loop. Keep allRecords() unchanged.
- [ ] Compare refreshed status values before assigning Published properties. Render no empty automatic subtitle.
- [ ] Remove empty-recipient help and repeated USB-failure paragraph; keep errors and destructive prompts.
- [ ] Render saved-file rows in a LazyVStack without changing identifiers, actions or selection.
- [ ] Verify focused native tests pass before the subsequent features.

## 2. Add approved conveniences after optimization

- [ ] Inspect existing catalog, USB export preflight and notification ownership before selecting exact extension points.
- [ ] Add received-file name search and type filters without changing stored originals or stale selection safety.
- [ ] Show/check required copy capacity, including ZIP expanded size, before writing; keep unknown-capacity and insufficient-capacity states distinct.
- [ ] Add permission-aware completion/interruption notifications, without blocking transfer when notifications are denied and without duplicate alerts.
- [ ] Add focused tests for each feature before implementation, then native UI/integration coverage.

## 3. Deliver verified update

- [ ] Align iOS version 0.3.48/build 59 in project, smoke assertions and README; leave Windows unchanged.
- [ ] Run python scripts/test-release-install-contract.py, python scripts/generate-install-qr.py --check, and git diff --check.
- [ ] Run fresh full native tests covering receiving, USB export, ZIP safety, sharing, deletion and the new features.
- [ ] Verify published canonical IPA and latest-target identity, version, CRC/hash and QR payload.
- [ ] Report tested limits. UI optimizations are not evidence of faster physical USB throughput.

## Baseline

0ef2447, clean tracked worktree, latest published release v0.3.47. Existing untracked verification artifacts are preserved. Native iOS execution uses macOS CI because this host is Windows.
