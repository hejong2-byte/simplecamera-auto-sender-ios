# iOS audit implementation — approved 2026-10-13

The user approved all findings and recommendations in `docs/audits/2026-10-13-ios-review.md` with “다 진행”. Baseline: 37da2ce, iOS 0.3.50 (61). Existing worktree/branch is reused. Source archive is `_task-backups/20261013-audit-37da2ce/source-37da2ce.zip` in the parent repository; SHA256 937e9cd516ca06344e5e850a7aad8f0bb7e8be1724b708f70baa07260bed05f2.

## Global constraints

- Preserve originals, ZIP CRC, incoming SHA, write/close errors, size checks and explicit overwrite approval. No default full USB SHA reread.
- Direct USB ZIP receive and stored-iPhone ZIP export reuse the same exporter and resume identity; preserve existing root flattening and original-change safeguards.
- Preserve Simple Cam-only automatic photo eligibility, bundle ID and existing sharing behavior.
- Do not touch real USB contents, unrelated files, Windows app or existing untracked artifacts. No external file sending or shutdown.
- Diagnostics exclude tokens, receive codes, message bodies, filenames and paths. Share only at user request; no automatic upload.
- Progress/status must describe actual evidence, not invented percentages or speedups.

## Design and validation

1. Core regression tests before production changes, native RED via macOS CI (no local Xcode). Compilation failure is not RED. Reuse existing injection seams and filesystem fixtures.
2. Surgical fixes in three isolated file groups. Native GREEN and scoped read-only reviews. Avoid new transfer queues and broad refactoring.
3. Settings features after core stabilization: current version/build, manual latest-release check with validated canonical install link; explicit privacy-safe diagnostics share with lifecycle cleanup. Separate tests before implementation.
4. Full native unit/UI suite, reviewed production diff, bump only iOS patch/build, build IPA and validate bundle/version/CRC/assets/QR from actual public artifacts.

## Task 1: USB correctness and I/O

Owner files: IPhoneUSBExportService.swift, USBReceiveService.swift, USBReceiveLedger.swift and their tests. R1 late collision must request overwrite consent. R2 verified staged ZIP must not be truncated or rewritten on resume; test non-chunk-aligned archive through runOnce, interrupted shared export, runOnce. R6 failed ordinary-file install plus rollback must preserve and report backup via USBCommitRecoveryError in both routes. O1 streaming SHA plus write/close/size only by default; no extra entire destination reread. Keep optional precise SHA. Tests must preserve original bytes and old target bytes on refused/failed replacements.

## Task 2: Local receive recovery and background durability

Owner files: IPhoneLocalReceiveEngine.swift, IPhoneLocalReceiveJobStore.swift, BackgroundIPhoneReceiveSession.swift, USBReceiverDependencies.swift and related tests. R3 transient failures require explicit safe retry on reapproval; SHA failures remain nonautomatic. R4 normal foreground poll pumps pending ACK before discovery without redownload or duplicate media import. R5 drain delivered completion/failure tasks before system background completion, and recover staging/job interruption safely. O3 coalesce progress checkpoints with deterministic timing while state changes and terminal events remain immediately durable. Test production callback wiring and serialized pump reentrancy.

## Task 3: UI acceptance, draft and large ZIP selection

Owner files: TextTransferViewModel.swift, USBReceiverViewModel.swift, ContentViewModel.swift, USBStorageManagementView.swift and related tests. R7 preserve draft edited during an awaited send; clear only unchanged sent draft. R8 accepted/rejected enqueue result must preserve selection on busy rejection and include actual manual upload busy state in USB explorer controls. No new queue. O2 replace ZIP deselection nested scans with linear/indexed ancestor-directory handling preserving hierarchy semantics; test 1,000 and 10,000 entries and folder behavior.

## Task 4: Settings support features

Owner files: new focused support services/views/tests, SettingsView.swift. Current version/build comes from bundle. Manual update fetch validates stable release, numeric newer version, expected repository/canonical bundle-named IPA; fixed known installation route only. No silent installation. Diagnostics use an allowlist of version/build, operation/stage, safe error domain/code and checkpoint counters/time, with no raw errors, names, paths or content. Temporary report share cleanup on dismissal/cancel. UI fixtures cover version and share entry, model tests cover network/parser failures and privacy canaries.

## Task 5: Integration, review and delivery

Controller owns CI/release scripts, version metadata, installation QR and final verification report. Run all native unit/UI tests and inspect results. Whole-branch independent review against 37da2ce; resolve significant findings. Verify released IPA and QR. Real iPhone/card-reader behavior remains unverified unless physically tested; never substitute simulator success for that claim.
