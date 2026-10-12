# iOS audit fixes and approved file conveniences

## Goal
Fix all six confirmed audit issues and both performance problems; add the four approved conveniences. Scope/design approved by the user with “다 진행 / 전부 수정”.

## Architecture
Retain existing iOS transfer pipeline and UI. Transactional changes belong in their owning stores; USB commit provenance and recoverable backups belong in the USB pipeline. MainActor only publishes snapshots. New convenience screens call the same validated transfer/export/share paths.

## Tech Stack
Swift, SwiftUI, UIKit, Foundation actors, XCTest/XCUITest, XcodeGen and GitHub macOS CI. Windows has no local Xcode: native results must come from CI.

## Global Constraints
- Baseline e949db50; reuse codex/received-file-sharing linked worktree. Do not modify unrelated untracked files.
- Backup: parent repository `_task-backups/20261012-audit-fixes-e949db50.zip`, 2240369 bytes, SHA256 A611E3C84CE946B79D8509A8C0E675B5C6B2EAA6A322EB1EDFABF250041B0A6C.
- Keep originals, bundle ID and Simple Cam-only automatic eligibility. No automatic full USB SHA reread. Keep ZIP CRC, size/write checks, overwrite approval and root-layout behavior.
- Do not send files to another computer or shut down. Chrome only if browser needed. No credentials in logs/history.
- Tests first: new regression tests on existing implementation must produce behavioral RED in native CI before corresponding fixes. New API compile errors are not RED evidence. Independent task owners coordinate tests into one CI run.
- Agents own disjoint files; root alone changes workflows, versions, commits/pushes and release. Each task receives independent spec/quality review. Publish only after full tests and IPA verification.

## Task A — ZIP/USB correctness and selective extraction
- [ ] Reproduce old same-size root file being skipped after interrupted ZIP, plus install failure with rollback failure.
- [ ] Replace size-based completion inference with durable committed-root provenance bound to source/destination/job. Ambiguous crash reprocesses the item; never claims completion from pre-existing size alone.
- [ ] Preserve backup on failed rollback and return recovery information; cleanup must not discard the remaining original. Exercise both local export and direct USB pipeline callers.
- [ ] Add ZIP entry metadata selection API without full-file reads. Selected entries and folder descendants retain existing wrapper-stripping layout, CRC, collision/capacity rules. Selection is part of resume identity; all-entry default remains compatible.
- [ ] Verify resumed capacity, rollback, root layout, CRC, selective file/folder extraction, empty/unsafe selection and changed-selection resume tests.

Files: App/Receive/IPhoneUSBExportService.swift, USBZIPReceivePipeline.swift, SafeZIPExtractor.swift and narrowly necessary related Receive types; their Tests. UI integration owned by Task C/root.

## Task B — upload atomicity, background drain and history/retry
- [ ] Reproduce interleaved job completion/enqueue updates and finish-events preceding durable completion.
- [ ] Move mutations into ManualTransferJobStore atomic operations; cache loaded state so progress reads do not decode disk repeatedly.
- [ ] Drain already-delivered delegate completion processing before system completion handler; do not wait on whole future transfers.
- [ ] Persist bounded manual-transfer outcome history (name, recipient identity, date, reason, retry source). Explicit retry targets failed entries only. Retain original recipient; stale document permission asks for re-selection instead of silent resend.
- [ ] Verify concurrent updates preserve jobs/counts/ETags, 1000 progress events, old state migration, failure history, exact recipient retry and stale document source.

Files: App/Media/ManualTransferJobStore.swift, App/Upload/ManualBackgroundTransferEngine.swift, BackgroundManualUploadSession.swift, related manual models plus Tests. Communicate public APIs to root for history UI; do not edit ContentView or USBReceiverViewModel.

## Task C — UI state correctness and file conveniences
- [ ] Reproduce USB root re-selection retaining old path/selection, foreground stale photo permission, and old catalog snapshot replacing new data.
- [ ] Reset browser state on successful root selection; use generation guards for stale async results.
- [ ] Refresh photo authorization when active without changing automatic photo matching.
- [ ] Move received-file catalog work off MainActor and coalesce refresh requests, retaining newest snapshot.
- [ ] Add multi-file sharing with URL validation and original preservation.
- [ ] Add folder-first name/date/size sort with stable ties to USB explorer.
- [ ] Integrate ZIP contents picker (Task A API) and history/failed retry screen (Task B API) after core interfaces available. Compact UI, no redundant explanation text; actionable error/reselection messages remain.
- [ ] Verify selection reset/race, foreground permissions, catalog responsiveness/latest list, multi-share supported/missing files, sorting stability and UI access to history/ZIP choices.

Files: App/UI/*, App/Application/USBReceiverDependencies.swift, App/Receive/USBStorageFileExplorer.swift, related UI/selection tests. Coordinate no overlapping edits with root.

## Task D — integration, independent review and delivery (root)
- [ ] Run contract/QR checks; one native RED run for combined regression tests.
- [ ] Inspect task diffs and independent review each group; fix important findings.
- [ ] Run focused GREEN and complete unit/UI suite; build unsigned IPA.
- [ ] Increment only iOS final version component/build after checking tags. Verify published IPA bundle/version/ZIP/aliases and installation QR.
- [ ] Report exact test results, changes, physical-device limits and final install QR here.

## Execution ledger
- Baseline tracked worktree clean; existing untracked artifacts preserved.
- Backup completed before edits. Native tests not yet run for this change.
