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
- [x] Reproduce old same-size root file being skipped after interrupted ZIP, plus install failure with rollback failure.
- [x] Replace size-based completion inference with durable committed-root provenance bound to source/destination/job. Ambiguous crash reprocesses the item; never claims completion from pre-existing size alone.
- [x] Preserve backup on failed rollback and return recovery information; cleanup must not discard the remaining original. Exercise both local export and direct USB pipeline callers.
- [x] Add ZIP entry metadata selection API without full-file reads. Selected entries and folder descendants retain existing wrapper-stripping layout, CRC, collision/capacity rules. Selection is part of resume identity; all-entry default remains compatible.
- [x] Verify resumed capacity, rollback, root layout, CRC, selective file/folder extraction, empty/unsafe selection and changed-selection resume tests.

Files: App/Receive/IPhoneUSBExportService.swift, USBZIPReceivePipeline.swift, SafeZIPExtractor.swift and narrowly necessary related Receive types; their Tests. UI integration owned by Task C/root.

## Task B — upload atomicity, background drain and history/retry
- [x] Reproduce interleaved job completion/enqueue updates and finish-events preceding durable completion.
- [x] Move mutations into ManualTransferJobStore atomic operations; cache loaded state so progress reads do not decode disk repeatedly.
- [x] Drain already-delivered delegate completion processing before system completion handler; do not wait on whole future transfers.
- [x] Persist bounded manual-transfer outcome history (name, recipient identity, date, reason, retry source). Explicit retry targets failed entries only. Retain original recipient; stale document permission asks for re-selection instead of silent resend.
- [x] Verify concurrent updates preserve jobs/counts/ETags, 1000 progress events, old state migration, failure history, exact recipient retry and stale document source.

Files: App/Media/ManualTransferJobStore.swift, App/Upload/ManualBackgroundTransferEngine.swift, BackgroundManualUploadSession.swift, related manual models plus Tests. Communicate public APIs to root for history UI; do not edit ContentView or USBReceiverViewModel.

## Task C — UI state correctness and file conveniences
- [x] Reproduce USB root re-selection retaining old path/selection, foreground stale photo permission, and old catalog snapshot replacing new data.
- [x] Reset browser state on successful root selection; use generation guards for stale async results.
- [x] Refresh photo authorization when active without changing automatic photo matching.
- [x] Move received-file catalog work off MainActor and coalesce refresh requests, retaining newest snapshot.
- [x] Add multi-file sharing with URL validation and original preservation.
- [x] Add folder-first name/date/size sort with stable ties to USB explorer.
- [x] Integrate ZIP contents picker (Task A API) and history/failed retry screen (Task B API) after core interfaces available. Compact UI, no redundant explanation text; actionable error/reselection messages remain.
- [x] Verify selection reset/race, foreground permissions, catalog responsiveness/latest list, multi-share supported/missing files, sorting stability and UI access to history/ZIP choices.

Files: App/UI/*, App/Application/USBReceiverDependencies.swift, App/Receive/USBStorageFileExplorer.swift, related UI/selection tests. Coordinate no overlapping edits with root.

## Task D — integration, independent review and delivery (root)
- [x] Run contract/QR checks; one native RED run for combined regression tests.
- [x] Inspect task diffs and independent review each group; fix important findings.
- [x] Run focused GREEN and complete unit/UI suite; build unsigned IPA.
- [x] Increment only iOS final version component/build after checking tags. Verify published IPA bundle/version/ZIP/aliases and installation QR.
- [x] Report exact test results, changes, physical-device limits and final install QR here.

## Execution ledger
- Baseline tracked worktree clean; existing untracked artifacts preserved.
- Backup completed before edits. Native tests not yet run for this change.
- 2026-10-12 resumed after explicit stop. Test-only commits: 484a1c4 and 49e7223; no production edits at resumption.
- Recovered cancelled native runs 38211160962 and 38211479456: their unit suites completed (551 tests / 18 failed assertions; 555 / 23). These are RED evidence, not successful CI runs.
- Confirmed behavioral failures: same-size uncommitted ZIP resume, recovery-backup cleanup, upload lost updates/completion ordering/progress disk dependence, USB catalog/reset races, missing history metadata and approved feature controls.
- Two rollback fault-injection tests unexpectedly passed. Repair and assert actual install/rollback failure injection before using them as regression evidence. Sort UI, foreground permission and catalog coalescing coverage still require verification.
- Corrected rollback injection: run 38213234809 (38afe45) executed 2 unit regressions and the sort UI regression; install/rollback fault assertions passed while original-survival assertions failed. Native behavioral RED confirmed.
- Run 38213346158 (323b0e6): 61 unit tests, 30 failed assertions, plus missing-sort UI failure. Selective extraction and exact-recipient retry stubs demonstrably failed before implementation.
- Additional run 38214128852 failed test compilation (missing chunkSize), not behavioral RED. Fixed the fixture in 4947491. Run 38214507723 then executed 87 tests with 28 failed assertions, including metadata filename collision, shared recovery path and lost ZIP selection checkpoint.
- Implemented A/B/C plus history and ZIP selection screens. Added selection persistence and legacy checkpoint compatibility. Local install contract, QR URI contract and whitespace checks pass; native GREEN remains pending.
- Independent B/C review found two further races: serialized retry backoff delaying completion drain, and concurrent receiving discarding ZIP subset selection. Added deterministic regressions first; corresponding fixes await the integrated native RED run.
- Integrated run 38215281667 failed SwiftUI type checking before tests. Split the receiver view modifier chains in bd948b1; this compile failure is not behavioral RED evidence.
- Run 38215645971 completed 590 unit tests (9 failed assertions, including one unexpected error) and 10 selected UI tests (one failed). The run was cancelled after both suites had reported their totals to recover logs; its conclusion is not GREEN. Failures reproduced ZIP finalization interrupted after an effective move, retry callback drain, ZIP picker concurrency, and multi-file sharing presentation.
- In e0ff618, added separate pending-root intent before finalization moves (ambiguous roots are reprocessed, not marked complete), delegated retry timing to background URLSession, retained ZIP selection until export acceptance, and consolidated share presentation. Strengthened ambiguous-move regression with incorrect same-size destination bytes. Independent review found no remaining actionable P1/P2 in these final changes.
- Focused native GREEN candidate 38217294375 runs all unit tests, then selected UI tests with unit log upload between stages. Candidate version is iOS 0.3.49 / build 60. Local SideStore install contract, QR URI and whitespace checks pass; native results and published IPA remain pending.
- Run 38217294375 unit stage passed: 591 tests, zero failures, completed 07:28:51 UTC. Selected UI stage remains in progress; full release suite and IPA verification are pending.
- The selected UI stage finished 9/10. The lone failure is confirmed to be the test's single-item navigation-bar locator: the screenshot and accessibility hierarchy show a working two-item activity sheet (`2 Documents`, `1 Image and 1 Document`). Corrected the locator and strengthened count/type, close, originals and selection assertions, without further production edits.
- To avoid repeating the same native build twice, the final release workflow will provide the final GREEN for all unit and all UI tests, including the corrected shared-file test. Publication remains gated on those tests and the IPA build/validation.
- Final screenshot inspection found the fourth action label truncated. Shortened its visible title to `임시 정리`, retaining the full accessibility label and confirmation logic. Cancelled unpublished release run 38218875720 and retained its tag unchanged; final candidate advanced only iOS to v0.3.50/build 61. Transfer logic remains identical to the 591-test GREEN candidate.
- Checkbox verification scope: Tasks A/B/C are supported by source review, the recorded behavioral RED runs, 591 passing unit tests and 9 passing selected UI tests in 38217294375. Photo authorization coverage uses injected denied/limited-to-authorized transitions and the foreground lifecycle hook; a physical Settings transition is not claimed. The corrected two-item share-sheet assertions, full release suite, IPA verification and final delivery remain pending under Task D in release run 38219230463 (32686ed, v0.3.50/build 61).
- Final GREEN: release run 38219230463 (32686ed) completed successfully with 591 unit + 35 UI tests, zero failures; unsigned IPA build and v0.3.50/build 61 publication succeeded. Final screenshots independently confirm multi-share and compact action controls.
- Downloaded canonical/legacy/latest IPA files are identical (3,304,083 bytes; SHA256 4334eee275323f9559979d9b5dbfdcc946db9dbdf0547c557501901f9dc2d64b). Bundle/version/build, ZIP CRC, Files flags, icons and privacy declaration passed. Downloaded installation QR matches the expected SideStore URI exactly and was visually checked. Final delivery is QR in this conversation, not an external transfer or shutdown.
- Final verification report records physical iPhone/USB/background/KakaoTalk limitations explicitly. No device throughput or physical media reliability claim is made.
