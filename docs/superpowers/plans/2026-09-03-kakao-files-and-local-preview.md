# Kakao files and local preview implementation plan

> **For agentic workers:** Use `executing-plans` inline, `test-driven-development`, and `verification-before-completion`. The user's office-PC rule prohibits unrequested parallel agents. Do not delegate or create another worktree.

**Goal:** Add selected Files documents to manual background transfer, remember the user-selected Kakao download folder, and deliver the approved local preview/receiver-card cleanup.

**Architecture:** Keep the existing manual job store, background engine, credentials and progress. Add a document source and a separate folder bookmark. Route file jobs to a dedicated general-file relay contract; do not weaken PhotoKit/automatic-photo validation. Local preview is a read-only operation on the existing received-file catalog.

**Tech stack:** SwiftUI, UIKit document picker, security-scoped bookmarks, NSFileCoordinator, Quick Look, XCTest, XcodeGen, macOS GitHub Actions.

## Constraints and evidence

- Specifications: `docs/superpowers/specs/2026-09-03-kakao-file-transfer-design.md` and `docs/superpowers/specs/2026-09-01-stored-file-preview-and-receiver-cleanup-design.md`.
- Do not modify the automatic filter, automatic baseline, upload ledger, receiver registration or original files.
- Keep the three existing manual kinds and their persisted raw values compatible. Add only `case file = "kakao-file"`.
- No assumed Kakao sandbox path. `directoryURL` is only the system picker's initial-location hint.
- USB and Kakao bookmarks must use different paths.
- 2 GiB per file, 95 MiB single-request limit, 32 MiB multipart size remain unchanged.
- The relay plan is `docs/superpowers/plans/2026-09-03-manual-general-file-relay.md` in the existing `codex/iphone-file-receive-storage` worktree. Local tests use its isolated Miniflare R2/D1, not live user files.
- A built IPA is not device verification or a deployed relay. Publish/tag/QR is separate from this approved implementation.

## Task 1: Establish failing contracts

**Files:** `UITests/ForegroundReceiveUITests.swift`, `Tests/ProjectSmokeTests.swift`.

- [ ] Re-run the unmodified iOS CI baseline at `f76bf1b` and record the result.
- [ ] Add a UI test for `app.buttons["manual-kakao-file"]`, after `manual-video`, and a Settings folder selector.
- [ ] Add a UI test asserting that the PC receive screen lacks `수신 기기` and retains stored-file actions.
- [ ] Add a stored-file preview UI test: select `keep-me.txt`, open it with `stored-file-open-keep-me.txt`, close it, and verify selection/delete availability are unchanged.
- [ ] Add a source contract asserting distinct preview wiring and absence of `identityCard` without testing unrelated formatting.
- [ ] Commit the failing tests and run CI. Verify failure is the absent feature, not a compilation/environment failure, before changing production code.

```swift
XCTAssertTrue(app.buttons["manual-kakao-file"].waitForExistence(timeout: 5))
XCTAssertFalse(app.staticTexts["수신 기기"].exists)
```

## Task 2: Read-only local preview and receiver cleanup

**Create:** `App/UI/StoredFilePreview.swift`, `Tests/IPhoneStoredFilePreviewTests.swift`.

**Modify:** `App/Receive/IPhoneReceivedFileCatalog.swift`, `App/UI/USBReceiverViewModel.swift`, `App/UI/USBReceiverView.swift`, `App/Application/USBReceiverDependencies.swift`, `App/Testing/ForegroundReceiveSimulation.swift`.

- [ ] Add tests with real temporary catalog files: readable file accepted; missing/outside/symlink/changed snapshot rejected; bytes/receipt records/selection untouched.
- [ ] Implement `func previewURL(for file: IPhoneStoredFile) throws -> URL` under the catalog lock. Require a regular readable direct child and matching snapshot. Do not alter persistence/enumeration.
- [ ] Inject `StoredFilePreviewAction = @Sendable (IPhoneStoredFile) throws -> URL` into the view model. Keep preview error and pending item separate from receive/USB outcomes.
- [ ] Add `openStoredFile(_:)` and a separate trailing `열기` button, preserving the existing row-selection identifier and behavior.
- [ ] Present a Quick Look navigation sheet with a close action and `.disabled` editing mode. Reject unsupported previews visibly.
- [ ] Remove only `identityCard` and its use; keep Settings registration/code.
- [ ] Suppress incoming-file prompts while preview/error is presented; do not clear pending incoming items.

## Task 3: Bookmark and document picker

**Create:** `App/Media/KakaoFolderStore.swift`, `App/UI/KakaoFilePickerModel.swift`, `App/Media/DocumentFilePicker.swift`, `Tests/KakaoFolderStoreTests.swift`, `Tests/KakaoFilePickerModelTests.swift`.

**Modify:** `App/Media/ManualMediaPicker.swift`, `App/UI/ContentView.swift`, `App/UI/SettingsView.swift`, `App/Application/AppDependencies.swift`, `App/Application/SimpleCameraAutoSenderApp.swift`, `App/Testing/ForegroundReceiveSimulation.swift`.

- [ ] Test first selection, cancellation, persisted bookmark restoration, missing/revoked folder, and reselect without touching a separate USB bookmark.
- [ ] Implement folder-only `save(_:)` / `resolve()` using a separate store file; balanced scope use and explicit stale/unavailable errors.
- [ ] Model `.folder` and `.files` picker states. Open file selection only after the folder picker has dismissed; cancel creates no jobs.
- [ ] Use `UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)` for the first picker; use `[.item]` and multiple selection for files. Set the saved folder as `directoryURL`.
- [ ] Add the fourth button and Settings folder/reselect card. Keep all existing action identifiers.
- [ ] Include picker/error/pending-dismissal state in the incoming-file presentation guard.
- [ ] Inject only temporary bookmark locations and fake transfer actions in simulator fixtures.

## Task 4: General document source and queue

**Create:** `App/Media/ManualDocumentSource.swift`, `Tests/ManualDocumentSourceTests.swift`.

**Modify:** `App/Media/ManualMediaTransferService.swift`, `App/Media/ManualTransferProgress.swift`, `App/UI/ContentViewModel.swift`, `App/Application/AppDependencies.swift`, `Tests/ManualMediaTransferServiceTests.swift`, `Tests/ManualTransferProgressTests.swift`, `Tests/ContentViewModelTests.swift`.

- [ ] Test real selected files with Korean names and unknown extensions, unchanged source hashes, missing/folder/symlink inputs, same names in different folders, and failed staging cleanup.
- [ ] Implement coordinated, scoped read-only copy into a UUID-owned staging file. Never delete or rename the source. Reject empty/oversize/changed files and report access/space errors distinctly.
- [ ] Add `enqueueFiles(_ urls: [URL]) async -> ManualMediaTransferSummary`. Share existing fingerprint/partition/enqueue code via a private export closure; do not copy the whole transfer pipeline.
- [ ] Ensure selected-file identifiers cannot enter the automatic photo ledger and existing job kinds still decode.
- [ ] Add `fileTransferReadinessMessage` and `sendSelectedFiles(_:)`; credential checks remain, photo permission is not required. An empty/cancelled selection changes no counts.
- [ ] Reuse progress and background transfer. Test all-failed, mixed preparation, queue restoration and 300 MiB multipart behavior with synthetic data only.

```swift
func enqueueFiles(_ urls: [URL]) async -> ManualMediaTransferSummary
func sendSelectedFiles(_ urls: [URL]) async
```

## Task 5: Dedicated relay requests

**Modify:** `App/Configuration/AppConfiguration.swift`, `App/Upload/RelayRequestFactory.swift`, `App/Upload/ManualBackgroundTransferEngine.swift`, `Tests/RelayRequestFactoryTests.swift`, `Tests/ManualBackgroundTransferEngineTests.swift`.

- [ ] Test `.file` single uploads use `PUT /api/files/:id`; file multipart start/parts/complete/abort use `/api/files/multipart`.
- [ ] Preserve current default media routes and original metadata headers.
- [ ] Include the file/media discriminator on retries and restored jobs, not just the initial request.
- [ ] Verify generic payload bytes, Korean filename and SHA-256 through the relay's isolated round-trip tests. Keep media/automatic routes restrictive.

## Task 6: Verify and hand off

- [ ] Run the worker's `npm test` and `npm run typecheck`; compare no pre-existing test regressions.
- [ ] Run iOS CI with all XCTest and UI tests, then `scripts/build-unsigned-ipa.sh` / `scripts/verify-ipa.py` through the configured workflow.
- [ ] Inspect screenshot attachments for the fourth action, Settings folder section, local preview and cleaned receiver screen.
- [ ] Review diffs for automatic filtering/credential/data changes and inspect git status for unrelated edits.
- [ ] Record CI commit/result, artifact path/hash, worker test counts and any live-deployment/device limitations. Do not label a source-only feature installed or live.

Windows test command: `gh run view <run-id> --repo hejong2-byte/simplecamera-auto-sender-ios --json status,conclusion,headSha,jobs`.

macOS test command: `bash scripts/test-ios.sh` (the workflow installs XcodeGen first).
