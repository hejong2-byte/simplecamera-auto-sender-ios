# Manual Photo, Screenshot, and Video Transfer Implementation Plan

**Goal:** Add three user-initiated multi-select transfers to the iPhone app and carry selected photos, screenshots, MOV files, and MP4 files safely through the existing relay to the Windows receiver.

**Architecture:** Keep the current automatic Simple Cam POST flow unchanged. Add a PhotoKit picker/export service and a metadata-aware explicit PUT upload for manual selections. Extend the relay and receiver with a 95MiB manual-media path while preserving the existing image-only 20MiB automatic path.

**Tech stack:** Swift 5, SwiftUI, PhotosUI, PhotoKit, CryptoKit, XCTest, Cloudflare Workers/R2, TypeScript/Vitest, Python/Pytest/Pillow.

## Constraints

- Transfer only picker-selected local identifiers; never scan unrelated assets for manual sending.
- Preserve bundle ID, Keychain identity, App Intent type, automatic baseline and existing ledger records.
- Keep automatic Simple Cam uploads backward compatible.
- Accept only JPEG, PNG, HEIC, HEIF, QuickTime MOV and MP4.
- Enforce 95MiB before a manual network request and in the relay/receiver.
- Stream manual uploads to R2; do not buffer a whole video in Worker memory.
- Keep videos out of image clipboard preparation.
- Do not publish an IPA, release, QR, or remote Worker deployment in this implementation pass.

## Task 1: Add the manual picker and original-media exporter

**Files:**
- Add `App/Media/ManualMediaPicker.swift`
- Add `App/Media/ManualMediaSource.swift`
- Add `App/Media/ManualMediaTransferService.swift`
- Add `Tests/ManualMediaSourceTests.swift`
- Add `Tests/ManualMediaTransferServiceTests.swift`

1. Add failing tests for resource preference, kind validation, selected-only transfer, batch continuation and summary counts.
2. Implement three media kinds and their PhotosUI filters.
3. Implement a system PHPicker wrapper with ordered unlimited selection.
4. Export the matching PhotoKit original resource with iCloud access enabled.
5. Transfer selected assets sequentially, clean temporary files and continue after per-file failures.
6. Run the iOS test suite in CI/macOS and commit.

## Task 2: Add metadata-aware manual upload requests

**Files:**
- Modify `App/Configuration/AppConfiguration.swift`
- Modify `App/Upload/RelayRequestFactory.swift`
- Modify `App/Upload/BackgroundUploadCoordinator.swift`
- Modify `Tests/RelayRequestFactoryTests.swift`
- Modify `Tests/DirectUploadCoordinatorTests.swift`

1. Add failing request tests for PUT URL, SHA-256, MIME type, encoded filename, captured time and size.
2. Add streaming file SHA-256 and deterministic remote UUID generation.
3. Add a manual upload descriptor without changing the existing automatic method behavior.
4. Reject files over 95MiB before transport starts.
5. Mark the shared ledger consistently and preserve HTTP/authentication error handling.
6. Run tests and commit.

## Task 3: Rebuild the iPhone home/settings layout

**Files:**
- Modify `App/UI/ContentView.swift`
- Modify `App/UI/ContentViewModel.swift`
- Add `App/UI/SettingsView.swift`
- Modify `App/Application/AppDependencies.swift`
- Modify `Tests/ContentViewModelTests.swift`
- Modify `project.yml`, `README.md`, and `docs/install.md`

1. Add failing view-model tests for manual working state and success/failure summaries.
2. Put `사진 전송`, `스크린샷 전송`, `동영상 전송` and `설정` on the home screen.
3. Move existing setup steps 1–4 and automatic recovery controls into settings.
4. Disable duplicate taps while a batch is running and display the last result.
5. Bump to version 0.1.7/build 5 and update user guidance.
6. Run the iOS suite and commit.

## Task 4: Extend the Cloudflare relay for streamed manual media

**Files:**
- Modify `SimpleCamera 업무사진 수신기/cloudflare/photo-relay/src/index.ts`
- Modify `SimpleCamera 업무사진 수신기/cloudflare/photo-relay/test/index.test.ts`

1. Add failing tests for MOV/MP4 metadata, 95MiB enforcement, stream upload, size mismatch and existing shortcut compatibility.
2. Generalize stored metadata and object extensions to supported media types.
3. Keep POST buffering/signature detection and its 20MiB limit unchanged.
4. Change explicit PUT to validate headers and stream the request body into R2.
5. Compare the stored object size with the declared size and delete mismatches.
6. Run Vitest and commit in the receiver repository.

## Task 5: Extend the Windows receiver safely

**Files:**
- Modify `SimpleCamera 업무사진 수신기/src/simplecamera_work_receiver/relay.py`
- Modify `SimpleCamera 업무사진 수신기/src/simplecamera_work_receiver/images.py`
- Modify `SimpleCamera 업무사진 수신기/src/simplecamera_work_receiver/receiver.py`
- Modify receiver tests for relay, validation, receiving and thumbnails.

1. Add failing tests for video metadata, MOV/MP4 extension safety and signature/hash validation.
2. Accept supported video MIME types and the 95MiB manual size.
3. Dispatch image files to Pillow verification and videos to ISO-BMFF signature verification after common size/hash checks.
4. Save and ACK videos but exclude them from image clipboard batches.
5. Leave video thumbnails as safe placeholders while retaining metadata and default-app opening.
6. Run the full Python suite and commit.

## Task 6: Verify the complete change without publishing

1. Run `npm test` for the Worker.
2. Run the full receiver `pytest` suite.
3. Run `git diff --check` in both repositories.
4. Push the iOS feature branch and use the macOS GitHub Actions test workflow for Swift/Xcode verification.
5. Confirm existing automatic Simple Cam tests and receiver image thumbnail tests still pass.
6. Report that production Worker deployment and SideStore IPA/QR publishing remain pending explicit deployment approval.
