# Fully Automatic Simple Cam Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing Simple Cam close automation immediately upload every new matching photo and report only confirmed HTTP successes, without pressing `지금 전송`.

**Architecture:** Keep the existing App Intent identity and strict metadata filter. Replace fire-and-forget background task enqueueing with an awaited file upload over one reusable foreground URLSession, start scanning at time zero, and use short adaptive retries only for PhotoKit originals that are not ready yet. Process every unhandled candidate, with the URL session limiting parallel connections to three.

**Tech Stack:** Swift 5, SwiftUI, App Intents, PhotoKit, ImageIO, URLSession, XCTest, XcodeGen, GitHub Actions

## Global Constraints

- Bundle identifier remains `com.hejong2byte.simplecameraautosender`.
- Minimum deployment target remains iOS 17.0 and CI remains Xcode 16.4-compatible.
- A photo is uploadable only at `6048 × 8064` or `8064 × 6048` with no case-insensitive `iPhone` text in TIFF camera model or EXIF lens model.
- App name, filename, `Software`, location, and other metadata never broaden matching.
- All unhandled matching photos are processed; there is no photo-count limit.
- The existing Shortcut/App Intent identity remains valid.
- `지금 전송` remains recovery-only.
- No success is counted before an HTTP `2xx` response.

---

## File map

- `App/Upload/BackgroundUploadCoordinator.swift`: replace background enqueue semantics with an awaited direct file upload and HTTP status validation while retaining the existing type name for minimal dependency churn.
- `App/Ledger/UploadLedger.swift`: allow an in-progress record without a background task identifier.
- `App/Sync/PhotoSyncService.swift`: report confirmed uploads and use immediate/adaptive scans instead of always waiting 15 seconds.
- `App/Automation/SendNewPhotosIntent.swift`: run the same intent in the foreground and return confirmed success/failure counts.
- `App/UI/ContentViewModel.swift`, `App/UI/ContentView.swift`: display confirmed completion rather than queue registration.
- `App/Application/SimpleCameraAutoSenderApp.swift`, `App/Application/AppDelegate.swift`: remove obsolete background-session callback wiring.
- `Tests/DirectUploadCoordinatorTests.swift`: prove `2xx`, network failure, and authentication behavior.
- `Tests/PhotoSyncServiceTests.swift`: prove all-photo batch handling, early completion, retry, and confirmed-count semantics.
- `Tests/ContentViewModelTests.swift`: follow the confirmed summary type.
- `README.md`, `docs/install.md`, `project.yml`: document automatic behavior and prepare v0.1.6.

### Task 1: Await actual relay completion

**Files:**
- Create: `Tests/DirectUploadCoordinatorTests.swift`
- Modify: `App/Upload/BackgroundUploadCoordinator.swift`
- Modify: `App/Ledger/UploadLedger.swift`
- Modify: `App/Application/SimpleCameraAutoSenderApp.swift`
- Delete: `App/Application/AppDelegate.swift`

**Interfaces:**
- Produces: `func upload(assetID: String, fileURL: URL) async throws` on `UploadCoordinating`.
- Produces: `HTTPFileUploading.upload(for:fromFile:)` for deterministic tests.
- Produces: `UploadHTTPError.server(statusCode:)` and `.invalidResponse`.

- [ ] **Step 1: Write failing direct-upload tests**

Add a fake transport returning an `HTTPURLResponse` and assert:

```swift
let coordinator = BackgroundUploadCoordinator(
    ledger: ledger,
    credentialStore: credentials,
    transport: StubHTTPFileUploader(statusCode: 201)
)
try await coordinator.upload(assetID: "simple-1", fileURL: fileURL)
XCTAssertEqual(try await ledger.record(id: "simple-1")?.state, .uploaded)
XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
```

For `401`, call `upload`, catch `UploadConfigurationError.authenticationBlocked`, and assert `coordinator.authenticationBlocked()` is `true`. For `503`, catch `UploadHTTPError.server(statusCode: 503)` and assert the record is not `.uploaded` and the source file still exists.

- [ ] **Step 2: Run CI to verify RED**

Run: push the test-only commit and execute `bash scripts/test-ios.sh` in GitHub Actions.

Expected: FAIL because `upload(assetID:fileURL:)` and the injected transport do not exist.

- [ ] **Step 3: Replace enqueue-only networking with awaited upload**

Use one reusable URLSession transport:

```swift
protocol HTTPFileUploading: Sendable {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPFileUploading {}

func upload(assetID: String, fileURL: URL) async throws {
    guard !authenticationBlocked() else {
        throw UploadConfigurationError.authenticationBlocked
    }
    guard let credential = try credentialStore.load() else {
        throw UploadConfigurationError.missingCredential
    }
    try await ledger.markQueued(id: assetID, taskIdentifier: nil)
    let request = try requestFactory.makeUploadRequest(credential: credential)
    let (_, response) = try await transport.upload(for: request, fromFile: fileURL)
    guard let http = response as? HTTPURLResponse else {
        throw UploadHTTPError.invalidResponse
    }
    switch http.statusCode {
    case 200...299:
        try await ledger.markUploaded(id: assetID)
        try FileManager.default.removeItem(at: fileURL)
    case 401, 403:
        setAuthenticationBlocked()
        throw UploadConfigurationError.authenticationBlocked
    default:
        throw UploadHTTPError.server(statusCode: http.statusCode)
    }
}
```

Configure the production session with `httpMaximumConnectionsPerHost = 3`. Remove background-session delegate code and the now-unused app delegate adapter.

- [ ] **Step 4: Run tests and commit**

Run: `bash scripts/test-ios.sh`

Expected: all direct-upload tests PASS.

Commit: `fix: await actual relay upload completion`

### Task 2: Scan immediately and send every matching photo

**Files:**
- Modify: `App/Sync/PhotoSyncService.swift`
- Modify: `Tests/PhotoSyncServiceTests.swift`
- Modify: `Tests/ContentViewModelTests.swift`

**Interfaces:**
- Produces: `SyncTransferSummary(discovered:matched:uploaded:failed:)`.
- Consumes: `UploadCoordinating.upload(assetID:fileURL:) async throws`.

- [ ] **Step 1: Write failing service tests**

Use four matching fixtures so the test proves the service does not select only one asset:

```swift
XCTAssertEqual(result.uploaded, 4)
XCTAssertEqual(uploader.recordedIDs, ["simple-1", "simple-2", "simple-3", "simple-4"])
```

```swift
let service = makeService(
    source: DelayedCandidatePhotoSource(availableOnScan: 3),
    scanDelaysNanoseconds: [0, 0, 0, 0]
)
let result = try await service.run(trigger: .automation)
XCTAssertEqual(result.uploaded, 1)
XCTAssertLessThan(source.scanCount, 5)
```

Use `ThrowingUploader(error: URLError(.notConnectedToInternet))`, then assert:

```swift
let result = try await service.run(trigger: .automation)
XCTAssertEqual(result.uploaded, 0)
XCTAssertEqual(result.failed, 1)
XCTAssertEqual(try await ledger.record(id: "simple-1")?.state, .failed)
```

- [ ] **Step 2: Run CI to verify RED**

Run: `bash scripts/test-ios.sh`

Expected: FAIL because the current summary reports `queued` and calls `enqueue`.

- [ ] **Step 3: Implement confirmed transfer semantics**

Rename the summary field and await every upload:

```swift
struct SyncTransferSummary: Sendable, Equatable {
    let discovered: Int
    let matched: Int
    let uploaded: Int
    let failed: Int
}
```

Use an immediate first scan followed by short retries:

```swift
scanDelaysNanoseconds: [UInt64] = [
    0,
    250_000_000,
    250_000_000,
    500_000_000,
    500_000_000,
    1_000_000_000,
    1_000_000_000,
    1_000_000_000
]
```

The first candidate scan happens before any sleep. Each scan processes every unhandled candidate. Once at least one matching photo completes and the following scan discovers no new candidate, exit early instead of consuming the remaining retry schedule. If no candidate or original is ready, continue the bounded retries. Skip only `.uploaded` and `.ignored`; `.failed` remains automatically retryable.

- [ ] **Step 4: Preserve strict filtering and unlimited batch behavior**

Do not change `SimpleCameraMetadataMatcher`. Iterate the full candidate array and never slice, cap, or select `.last`/`.first`.

- [ ] **Step 5: Run all tests and commit**

Run: `bash scripts/test-ios.sh`

Expected: all tests PASS, including all existing metadata and ledger tests.

Commit: `fix: transfer every Simple Cam photo immediately`

### Task 3: Make the existing automation truthful and automatic

**Files:**
- Modify: `App/Automation/SendNewPhotosIntent.swift`
- Modify: `App/UI/ContentViewModel.swift`
- Modify: `App/UI/ContentView.swift`
- Modify: `Tests/ContentViewModelTests.swift`

**Interfaces:**
- Consumes: `SyncTransferSummary.uploaded` and `.failed`.
- Preserves: `SendNewSimpleCameraPhotosIntent` type and its existing shortcut title.

- [ ] **Step 1: Add source-level smoke assertions**

Add these compile-time/runtime assertions and update every view-model fixture to construct `SyncTransferSummary`:

```swift
XCTAssertEqual(SendNewSimpleCameraPhotosIntent.title, "새 SimpleCamera 사진 전송")
XCTAssertTrue(SendNewSimpleCameraPhotosIntent.openAppWhenRun)
```

- [ ] **Step 2: Change the intent to automatic foreground execution**

```swift
static let openAppWhenRun = true

func perform() async throws -> some IntentResult & ProvidesDialog {
    let summary = try await AppDependencies.shared.syncService.run(trigger: .automation)
    let message = summary.failed == 0
        ? "\(summary.uploaded)장 전송 완료"
        : "\(summary.uploaded)장 완료, \(summary.failed)장 재시도 대기"
    return .result(dialog: IntentDialog(stringLiteral: message))
}
```

The foreground transition is automatic; it does not require the user to press `지금 전송` or edit the existing automation.

- [ ] **Step 3: Correct UI copy**

Change `전송 시작` to `전송 완료` and label `지금 전송` as an error-recovery action in supporting text. Keep the button functional.

- [ ] **Step 4: Run tests and commit**

Run: `bash scripts/test-ios.sh`

Expected: all tests PASS.

Commit: `fix: report only confirmed automatic transfers`

### Task 4: Prepare and verify v0.1.6

**Files:**
- Modify: `project.yml`
- Modify: `README.md`
- Modify: `docs/install.md`

- [ ] **Step 1: Update release metadata**

Set the exact `project.yml` values below, delete the README sentence claiming a 15-second retry, and replace it with `단축키 실행 즉시 새 Simple Cam 사진 전송을 시작하고 서버 성공을 확인합니다.`:

```yaml
CURRENT_PROJECT_VERSION: 4
MARKETING_VERSION: 0.1.6
```

- [ ] **Step 2: Run contamination scans and full CI**

Run:

```bash
rg -n -i "all photos|모든 새 사진|사진함 전체 전송|\.last\b|\.first\b" App Tests README.md docs/install.md
bash scripts/test-ios.sh
bash scripts/build-unsigned-ipa.sh
```

Expected: no broad-scope transfer text or single-photo selection; tests and unsigned IPA build PASS.

- [ ] **Step 3: Merge, tag, and publish**

Merge only after branch CI passes. Tag `v0.1.6`, let the release workflow publish `SimpleCameraAutoSender.ipa` and `install-qr.png`, then download both assets and compare checksums with the release.

- [ ] **Step 4: Device acceptance before claiming completion**

Use the already configured automation without pressing `지금 전송`:

1. Take one Simple Cam photo and close the app; confirm exactly one PC arrival.
2. Take multiple Simple Cam photos and close once; confirm all arrive exactly once.
3. Take an iPhone Camera photo and a screenshot; confirm neither arrives.
4. Confirm the intent-reported completed count equals relay/PC arrivals.

Do not claim automatic transfer is complete until these device checks pass.
