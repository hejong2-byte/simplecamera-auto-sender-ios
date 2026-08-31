# Automatic Transfer Audit Implementation Plan

> **For agentic workers:** Use executing-plans inline; no delegation. Steps use checkbox syntax.

**Goal:** Fix misleading/missing automatic transfers, then add explicit local-file deletion and remove the redundant safety information card.

**Architecture:** Preserve the existing PhotoSyncService, progress store, and received-file catalog boundaries. Separate candidate classification from transfer outcomes, recover interrupted work, and keep all deletion behind a confirmed, validated selection.

**Tech Stack:** Swift 5, SwiftUI, PhotoKit, ImageIO, XCTest, XcodeGen, macOS GitHub Actions.

## Global Constraints

- Bundle ID com.hejong2byte.simplecameraautosender, iOS 17 minimum.
- Keep 6048 x 8064 / 8064 x 6048 plus absence of iPhone model/lens markers.
- No photo-count cap; uploads remain sequential.
- Preserve Shortcut identity, credentials, baseline, and production files.
- Test files/ledgers use fresh per-test temporary directories only.
- Keep USB/file size and SHA-256 verification.

### Task 1: Automatic-transfer regressions

**Files:** Tests/PhotoSyncServiceTests.swift, Tests/AutomaticTransferProgressTests.swift, Tests/DirectUploadCoordinatorTests.swift, Tests/ContentViewModelTests.swift.

**Interfaces:** Existing PhotoSyncService.run(trigger:), AutomaticTransferProgressReporter, HTTPFileUploading, and ContentViewModel.

- [ ] Add regressions for rejected candidate counts, orphan queued photos,
  pending metadata after an earlier success, success-preserving interruption,
  and export cleanup after HTTP acknowledgement. Keep fixture upload semantics
  faithful: successful upload marks uploaded, not just queued.

~~~swift
XCTAssertEqual(result.uploaded, 1)
XCTAssertEqual(progress?.uploadedCount, 1)
XCTAssertEqual(progress?.failedCount, 0)
XCTAssertEqual(record?.state, .uploaded)
~~~

- [ ] Commit tests only and push the existing branch; run CI bash scripts/test-ios.sh.
  Expect behavioral assertion failures, not compilation failures.
- [ ] Fix only the traced paths in App/Sync/PhotoSyncService.swift,
  App/Sync/AutomaticTransferProgress.swift, App/Photos/SimpleCameraMetadataMatcher.swift,
  App/Ledger/UploadLedger.swift, App/Upload/BackgroundUploadCoordinator.swift,
  and automatic presentation in App/UI/ContentViewModel.swift / ContentView.swift.

~~~swift
if record.state == .uploaded || record.state == .ignored { continue }
guard try metadataMatcher.matches(fileURL: fileURL) else {
    try await ledger.markIgnored(id: candidate.localIdentifier)
    continue
}
~~~

- [ ] Recover persisted pending work on the next automatic run or explicit retry;
  do not add photo scanning to manual transfer callbacks or general UI refresh.
  Verify manual-progress updates leave automatic progress intact.
- [ ] Run complete simulator tests and confirm the regressions pass.

### Task 2: Confirmed manual local-file deletion

**Files:** App/Receive/IPhoneReceivedFileCatalog.swift,
App/UI/USBReceiverViewModel.swift, App/UI/USBReceiverView.swift,
App/Application/USBReceiverDependencies.swift, catalog/view-model/UI tests.

**Interfaces:** IPhoneStoredFile, catalog refresh(), captured selected file
snapshots, injected asynchronous delete action returning deleted IDs and failures.

- [ ] Add failing tests for selected-only deletion, cancel, changed/missing
  originals, paths outside the received directory, partial failure, and
  selection/list refresh.
- [ ] Implement catalog validation and per-file deletion; preserve records as
  transfer history and prevent duplicate receipt of deliberately removed files.

~~~swift
guard file.url.standardizedFileURL.deletingLastPathComponent()
    == receivedDirectory.standardizedFileURL else {
    throw CocoaError(.fileWriteNoPermission)
}
~~~

- [ ] Add a confirmation driven by a captured selection, busy guards, and clear
  completion/error text. Remove only the operationNotice view and call.
- [ ] Run the full simulator suite; inspect deletion UI in a fixture with
  synthetic files and verify cancel does not delete anything.

### Task 3: Build and deliver

**Files:** project.yml, Tests/ProjectSmokeTests.swift, docs/install.md, release notes.

- [ ] Prepare the next unused release version after tests pass.
- [ ] Build with bash scripts/build-unsigned-ipa.sh on macOS CI.
- [ ] Download the release IPA; run python scripts/verify-ipa.py, inspect its
  Info.plist, check ZIP integrity, and compare SHA-256 after the Desktop copy.
- [ ] Provide verified Desktop IPA and concise verified causes/test results;
  explicitly distinguish simulator coverage from physical-device acceptance.
