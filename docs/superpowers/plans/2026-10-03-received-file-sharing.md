# Received File Sharing Implementation Plan

> **For agentic workers:** Use executing-plans for this single, tightly coupled UI/model task. Execute inline in the existing isolated worktree.

**Goal:** Share received photos/PDFs to KakaoTalk through the iOS share sheet without leaving the received-file list first.

**Architecture:** Reuse `IPhoneReceivedFileCatalog.previewURL(for:)` for validating the local original. A small UIKit share-sheet wrapper consumes that URL. `USBReceiverViewModel` owns presentation/error state; `ContentView` defers incoming prompts while it is presented.

**Tech Stack:** Swift 5, SwiftUI, UIKit, UniformTypeIdentifiers, XCTest, iOS 17+, existing macOS GitHub Actions.

## Global Constraints

- iPhone only; no new SDK, network upload, or automatic message send.
- Photo/PDF only; one original file per button. Preserve original and USB/delete selection on cancel/completion.
- No success message claiming KakaoTalk delivery. Errors belong to sharing, not receiving.
- Keep USB/delete/temporary-cleanup row and existing receiver behavior unchanged.
- Version 0.3.46, build 57; bundle ID and canonical IPA filename stay unchanged.

## Task 1: Validated file sharing and delivery

**Files:**
- Create `App/UI/StoredFileShareSheet.swift`, `Tests/USBReceiverStoredFileSharingTests.swift`.
- Modify `App/UI/USBReceiverViewModel.swift`, `App/UI/USBReceiverView.swift`, `App/UI/ContentView.swift`.
- Extend `App/Testing/ForegroundReceiveSimulation.swift` and `UITests/ForegroundReceiveUITests.swift` with opt-in PDF/PNG fixtures.
- Create `.github/workflows/file-share-regression.yml` for focused macOS tests.
- Update `project.yml`, `README.md`, `docs/install.md` after verification.

**Interfaces:**
- Consume `previewStoredFile: (IPhoneStoredFile) throws -> URL`, `storedFilesProvider`, existing operation flags.
- Produce `sharingFile: IPhoneStoredFile?`, `storedFileShareError: String?`, `canShareStoredFile(_:)`, `shareStoredFile(_:)`, `finishSharingStoredFile(error:)`.
- `StoredFileShareSheet(file:onFinish:)` passes `[file.url]` to `UIActivityViewController` and reports errors on the main actor.

- [ ] RED: Add a real PNG/PDF simulation and UI test. Test looks for `stored-file-share-받은 문서.pdf`/`stored-file-share-받은 사진.png`, opens the system sheet, cancels, and checks originals/selection remain. Run focused Actions against pre-feature code; expect missing-button assertion failure, not a build failure.
- [ ] Add model tests against a real temporary catalog, covering images/PDF/unsupported formats, missing/modified/outside-catalog originals, receive/error/selection preservation, blocked deletion and competing dialogs, and busy receive.
- [ ] Implement type filtering using `UTType(filenameExtension: file.url.pathExtension)` conforming to `.image` or `.pdf`. Revalidate with `previewStoredFile`, then publish the sharing snapshot; catch errors separately and refresh the catalog.
- [ ] Implement the sheet using `UIActivityViewController(activityItems: [file.url], applicationActivities: nil)` and `completionWithItemsHandler`; no decoding of large photos into memory or temporary extra copies.
- [ ] Add the compact per-file button and separate share-error alert. Extend incoming-dialog gating with `sharingFile == nil && storedFileShareError == nil`. Guard deletion while sharing.
- [ ] GREEN: Run focused unit/UI tests and inspect the screenshots. Run `python scripts/test-release-install-contract.py` and `git diff --check` locally. Review changed files for unrelated changes.
- [ ] Bump version, document the exact tap sequence, commit and run full release tests using the existing release workflow. Download/verify IPA version, bundle ID, aliases/digest and QR payload; present QR with physical KakaoTalk validation limits.

## Progress

Design approved; existing linked worktree reused on `codex/received-file-sharing`. Baseline install contract passes locally. No local Xcode is available; macOS Actions is the Swift/iOS runtime validation environment.
