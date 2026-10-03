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

- [x] RED: Add a real PNG/PDF simulation and UI test. Test looks for `stored-file-share-받은 문서.pdf`/`stored-file-share-받은 사진.png`, opens the system sheet, cancels, and checks originals/selection remain. Run focused Actions against pre-feature code; expect missing-button assertion failure, not a build failure.
- [x] Add model tests against a real temporary catalog, covering images/PDF/unsupported formats, missing/modified/outside-catalog originals, receive/error/selection preservation, blocked deletion and competing dialogs, and busy receive.
- [x] Implement type filtering using `UTType(filenameExtension: file.url.pathExtension)` conforming to `.image` or `.pdf`. Revalidate with `previewStoredFile`, then publish the sharing snapshot; catch errors separately and refresh the catalog.
- [x] Implement the sheet using `UIActivityViewController(activityItems: [file.url], applicationActivities: nil)` and `completionWithItemsHandler`; no decoding of large photos into memory or temporary extra copies.
- [x] Add the compact per-file button and separate share-error alert. Extend incoming-dialog gating with `sharingFile == nil && storedFileShareError == nil`. Guard deletion while sharing.
- [x] GREEN: Run focused unit/UI tests and inspect the screenshots. Run `python scripts/test-release-install-contract.py` and `git diff --check` locally. Review changed files for unrelated changes.
- [x] Bump version, document the exact tap sequence, commit and run full release tests using the existing release workflow. Download/verify IPA version, bundle ID, aliases/digest and QR payload; present QR with physical KakaoTalk validation limits.

## Progress

Design approved; existing linked worktree reused on `codex/received-file-sharing`. Baseline install contract passes locally. No local Xcode is available; macOS Actions is the Swift/iOS runtime validation environment.

RED run 37100430717 on 757ac59: 16 existing deletion tests passed; the new UI test failed exactly at the absent share button (line 17). The app and test code compiled. Green verification is pending.

Implementation run 37100969927: all 26 unit tests passed. The UI failure was a test locator: the native share sheet exposes `UIActivityContentView`/`header.closeButton`, not a custom controller-view identifier. The failure hierarchy already contained the actual PDF payload. Removed the ineffective identifier and checked the observed native header plus re-enabled share action after cancellation.

GREEN run 37101653830 on f450cbe: 26 unit tests and 1 UI test passed. Inspected both captured native sheets: `받은 문서.pdf` has document actions; `받은 사진.png` has image actions. Both close/cancel paths preserve the original rows and prior deletion selection. Install URI/bundle-ID contract and whitespace checks passed locally. Source changes remain limited to the approved sharing feature, simulation/tests, and version/install documentation.

Release preparation: version 0.3.46/build 57 is set; full release regression and IPA/QR verification are still pending. Actual KakaoTalk conversation delivery cannot be exercised on this simulator.

First full release run 37102068588: all 28 UI tests passed, including sharing. Among 487 unit tests, two ProjectSmokeTests produced three failed assertions solely because their expected version/build/readme text still named 0.3.45/56. No IPA was published. Updated those three expectations to the approved 0.3.46/57 and included ProjectSmokeTests in the focused workflow so version drift is caught earlier. App code is unchanged from the fully passing sharing/UI run; full release verification will be rerun before delivery.

## Delivered verification

- Release run [37102951466](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/37102951466) passed on `4d2c9838f1ffc3d29dd338d116bfdbbb39961e59`: 487 unit tests and 28 UI tests, zero failures. IPA build and publication passed.
- [v0.3.46](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/tag/v0.3.46) published 2026-10-03. Downloaded IPA contains version `0.3.46`, build `57`, bundle ID `com.hejong2byte.simplecameraautosender`; archive CRC, Files sharing, and in-place document visibility checks passed.
- Canonical IPA, legacy alias, and a fresh download from the QR's `releases/latest` target have identical SHA-256: `dca9d3ef4c40f84db311cd184601579cb9bb85971a1d553f9b6589ef40d22392`.
- Published QR SHA-256: `5dd07fed72388309ef0b8e3d505af216d8a5199a6235b9c7312796e323d8b568`. Its pixels exactly match a newly constructed QR for the validated canonical SideStore URI.
- Downloaded artifacts and test screenshots are in `release-v0.3.46-verify/`. Test data is synthetic; no user file or KakaoTalk message was sent. Real KakaoTalk conversation delivery remains an explicitly unverified device-side step.
