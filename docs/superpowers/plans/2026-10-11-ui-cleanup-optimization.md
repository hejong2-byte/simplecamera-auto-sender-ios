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

- [x] Add a real-ledger refresh test covering every asset state, stale failure removal and unchanged persisted records.
- [x] After initial refresh, subscribe to model.objectWillChange, repeat refresh, and assert zero emissions. Mutate the ledger and assert new values still publish.
- [x] Assert idle automatic status has no explanatory subtitle and routine screens omit repetitive help without losing error/recovery/deletion controls.
- [x] Run focused native tests against unchanged production code and record actual failing assertions.
- [x] Add UploadLedger.statusSummary() returning baseline, queued/uploaded/failed counts and failure categories from one unsorted snapshot loop. Keep allRecords() unchanged.
- [x] Compare refreshed status values before assigning Published properties. Render no empty automatic subtitle.
- [x] Remove empty-recipient help and repeated USB-failure paragraph; keep errors and destructive prompts.
- [x] Render saved-file rows in a LazyVStack without changing identifiers, actions or selection.
- [x] Verify focused native tests pass before the subsequent features. Run 38096300663: 65 unit + 4 UI tests pass on fa6f0f7; independent fix review approved.

## 2. Add approved conveniences after optimization

- [x] Inspect existing catalog, USB export preflight and notification ownership before selecting exact extension points.
- [x] Add received-file name search and type filters without changing stored originals or stale selection safety.
- [x] Show/check required copy capacity, including ZIP expanded size, before writing; keep unknown-capacity and insufficient-capacity states distinct.
- [x] Add permission-aware completion/interruption notifications, without blocking transfer when notifications are denied and without duplicate alerts.
- [x] Add focused tests for each feature before implementation, then native UI/integration coverage. Run 38098868059 on 40443fd: 244 unit + 6 UI tests pass. Task and whole-branch follow-up reviews approved; first-failure capacity and approval-only notification findings are fixed and covered by real-file regressions.

## 3. Deliver verified update

- [x] Align iOS version 0.3.48/build 59 in project, smoke assertions and README; leave Windows unchanged.
- [x] Run python scripts/test-release-install-contract.py, python scripts/generate-install-qr.py --check, and git diff --check.
- [x] Run fresh full native tests covering receiving, USB export, ZIP safety, sharing, deletion and the new features. Release run 38099610117 on 12ff351: 540 unit + 31 UI tests, zero failures; native IPA build succeeded.
- [x] Verify published canonical IPA and latest-target identity, version, CRC/hash and QR payload. v0.3.48/build 59: canonical, legacy alias and latest download are byte-identical (3,172,596 bytes; SHA256 b7aa23e9faa22b993d2d8f3cdbd16191f410874980498f60dd720b68128d5217), match GitHub asset digests, and pass archive, bundle, icons, Files and privacy-manifest checks. Published QR matches the validated canonical install URI.
- [x] Report tested limits. Native simulator tests and artifact checks do not measure physical USB/reader throughput, demonstrate installed KakaoTalk delivery, or extend iOS background execution time. User files and installed apps were not deleted or modified during verification.

## Baseline

0ef2447, clean tracked worktree, latest published release v0.3.47. Existing untracked verification artifacts are preserved. Native iOS execution uses macOS CI because this host is Windows.
