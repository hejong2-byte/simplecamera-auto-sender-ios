# Optimization report

Range: 0ef2447..fa6f0f7267db90ff636959d08176621b2976bf78

Implemented ledger status summary in one unsorted actor pass, guarded status property assignments, removed idle helper/empty saved-recipient helper/repeated USB failure paragraph, and lazy stored-file rows. Preserved errors, destructive confirmation, preview/share and progress. Original five source files copied into parent repository _task-backups/20261011-ui-optimization before production edits.

Native RED: GitHub Actions run 38095359779. 65 unit tests, 6 assertion failures: unchanged refresh emits 7 rather than 0 on two refreshes; idle subtitle matches old explanation instead of empty twice; two removed-copy assertions fail. All count/state/persistence, sharing model and deletion model tests pass. Four UI tests: expected home/text helper failures, ZIP share passes. Photo/PDF share hit 10-second UIActivityContentView timeout. Captured AX hierarchy showed ActivityListView/ShareSheet.RemoteContainerView present but remote controls not loaded; no application error alert. Increased system share-sheet wait from 10 to 30 seconds, retaining all visibility and enabled/original/selection assertions.

Local validation: pythoncore-3.14-64/python.exe scripts/test-release-install-contract.py and scripts/generate-install-qr.py --check both pass. git diff --check passes (only Git's CRLF conversion notices).

Native GREEN: commit fa6f0f7267db90ff636959d08176621b2976bf78, GitHub Actions run 38096300663, success. Superseded run 38096138353 was canceled. No physical iPhone/USB throughput or installed Kakao share test is claimed.

Follow-up fix: `ContentViewModel.refresh()` now awaits `ledger.statusSummary()` before synchronously reading Photos authorization and credential availability. Those values are therefore read after the suspension point, so a concurrent credential save or permission completion is not overwritten by a stale pre-await snapshot. `testRefreshCountsEveryStateAndPreservesLedgerContents` now compares the ledger file bytes before and after refresh in addition to comparing in-memory records.

Local verification: `git diff --check` passed (Git emitted only LF-to-CRLF conversion notices). Xcode is unavailable on this Windows host; native verification ran on the macOS CI runner.

Native command: `xcodegen generate`, then `xcodebuild test -project SimpleCameraAutoSender.xcodeproj -scheme SimpleCameraAutoSender -destination platform=iOS\ Simulator,id=<available-iPhone-UDID> -parallel-testing-enabled NO -resultBundlePath build/FileShareTests.xcresult` with the four unit classes and four UI cases selected by `.github/workflows/file-share-regression.yml`, `CODE_SIGNING_ALLOWED=NO`.

Actual GREEN log summary: ContentViewModelTests 17, ProjectSmokeTests 21, USBReceiverManualDeletionTests 16, USBReceiverStoredFileSharingTests 11; total 65 unit tests, 0 failures. ForegroundReceiveUITests 4 tests, 0 failures. `testRefreshCountsEveryStateAndPreservesLedgerContents`, `testRefreshSkipsUnchangedPublicationsButStillPublishesNewLedgerState`, photo/PDF share and ZIP share tests all passed. Final output: `** TEST SUCCEEDED **`. Verified with `gh run view 38096300663 --repo hejong2-byte/simplecamera-auto-sender-ios --log` on October 11 (KST).
