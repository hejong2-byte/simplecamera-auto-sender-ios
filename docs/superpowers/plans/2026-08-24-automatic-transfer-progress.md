# Automatic Transfer Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a live, actual-byte progress bar for fully automatic Simple Cam transfers while uploading every matched photo sequentially, one file at a time.

**Architecture:** Add an automatic-only progress model, replaying in-memory store, and thread-safe reporter shared by the App Intent and main UI. Extend the direct foreground uploader to report `URLSessionTaskDelegate` byte callbacks, then make `PhotoSyncService` prepare and upload matched files sequentially while publishing stages and aggregate bytes. Keep the automatic ledger and manual-transfer queue unchanged.

**Tech Stack:** Swift 5, SwiftUI, App Intents, PhotoKit, URLSession delegates, XCTest, XcodeGen, GitHub Actions, SideStore unsigned IPA.

## Global Constraints

- Automatic transfers have no photo-count limit.
- Automatic photos upload in creation-date order, exactly one active upload at a time.
- Percent uses actual sent bytes, not completed-photo count.
- A photo counts as complete only after the server returns HTTP `2xx`.
- One failed photo does not stop later photos; it remains retryable in the existing ledger.
- Automatic progress state must not be written into the automatic asset ledger or manual-transfer queue.
- Existing Simple Cam origin filtering, bundle identifier, Keychain data, manual media transfer, and test install URL remain unchanged.
- Production source changes follow RED → GREEN; Windows cannot run Xcode, so each verification push uses the macOS GitHub Actions CI.

---

## File Structure

- Create `App/Sync/AutomaticTransferProgress.swift`: automatic stages, progress value, replaying store, and aggregate reporter.
- Create `Tests/AutomaticTransferProgressTests.swift`: percent calculation and replay behavior.
- Modify `App/Upload/BackgroundUploadCoordinator.swift`: progress-aware upload protocol and URLSession delegate transport.
- Modify `Tests/DirectUploadCoordinatorTests.swift`: prove byte callbacks are forwarded before HTTP completion.
- Modify `App/Sync/PhotoSyncService.swift`: sequential preparation/upload and progress publication.
- Modify `Tests/PhotoSyncServiceTests.swift`: prove one-at-a-time transfer, aggregate bytes, continuation after failure, and completion.
- Modify `App/Application/AppDependencies.swift`: create one shared automatic progress store and inject it into service and view model.
- Modify `App/UI/ContentViewModel.swift`: subscribe to automatic progress and expose display text.
- Modify `Tests/ContentViewModelTests.swift`: prove replayed progress and server errors reach the UI model.
- Modify `App/UI/ContentView.swift`: add the automatic status card above manual controls.
- Modify `project.yml`: bump build `7` to `8` after behavior is green.
- Modify `README.md` and `docs/install.md`: document sequential automatic progress.

---

### Task 1: Automatic Progress Model and Replaying Store

**Files:**
- Create: `App/Sync/AutomaticTransferProgress.swift`
- Create: `Tests/AutomaticTransferProgressTests.swift`

**Interfaces:**
- Produces: `AutomaticTransferStage`, `AutomaticTransferProgress`, `AutomaticTransferProgressStore`, and `AutomaticTransferProgressReporter`.
- `AutomaticTransferProgressStore.updates() -> AsyncStream<AutomaticTransferProgress>` immediately yields its latest value.
- `AutomaticTransferProgressReporter` owns one run ID and publishes scanning, preparation, upload, verification, success, failure, and final states synchronously.

- [ ] **Step 1: Write failing model and replay tests**

Create tests that express the public behavior:

```swift
import XCTest
@testable import SimpleCameraAutoSender

final class AutomaticTransferProgressTests: XCTestCase {
    func testPercentUsesCompletedAndCurrentActualBytes() {
        let progress = AutomaticTransferProgress(
            runID: UUID(),
            stage: .uploading,
            currentIndex: 2,
            totalCount: 3,
            uploadedCount: 1,
            failedCount: 0,
            totalBytes: 1_000,
            completedBytes: 400,
            currentBytesSent: 250,
            currentBytesTotal: 300,
            failureCategories: []
        )

        XCTAssertEqual(progress.displayedBytesSent, 650)
        XCTAssertEqual(progress.percent, 65)
    }

    func testLateSubscriberImmediatelyReceivesLatestProgress() async {
        let store = AutomaticTransferProgressStore()
        let latest = AutomaticTransferProgress.scanning(runID: UUID())
        store.publish(latest)

        var iterator = store.updates().makeAsyncIterator()

        XCTAssertEqual(await iterator.next(), latest)
    }
}
```

- [ ] **Step 2: Push the RED test and verify expected failure**

Run:

```powershell
git add Tests/AutomaticTransferProgressTests.swift
git commit -m "test: define automatic transfer progress"
git push
$runId = gh run list --branch codex/background-manual-transfer-progress --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $runId --exit-status
```

Expected: CI fails because `AutomaticTransferProgress` and its store do not exist.

- [ ] **Step 3: Implement the minimal model, store, and reporter**

Create the focused source file with these exact responsibilities:

```swift
enum AutomaticTransferStage: Sendable, Equatable {
    case idle, scanning, preparing, uploading, verifying, completed, failed
}

struct AutomaticTransferProgress: Sendable, Equatable {
    var runID: UUID
    var stage: AutomaticTransferStage
    var currentIndex: Int
    var totalCount: Int
    var uploadedCount: Int
    var failedCount: Int
    var totalBytes: Int64
    var completedBytes: Int64
    var currentBytesSent: Int64
    var currentBytesTotal: Int64
    var failureCategories: Set<UploadErrorCategory>

    var displayedBytesSent: Int64 {
        min(max(completedBytes + currentBytesSent, 0), max(totalBytes, 0))
    }

    var percent: Int {
        guard totalBytes > 0 else { return stage == .completed ? 100 : 0 }
        return min(Int(Double(displayedBytesSent) / Double(totalBytes) * 100), 100)
    }

    static func idle(runID: UUID = UUID()) -> Self {
        .init(
            runID: runID, stage: .idle,
            currentIndex: 0, totalCount: 0,
            uploadedCount: 0, failedCount: 0,
            totalBytes: 0, completedBytes: 0,
            currentBytesSent: 0, currentBytesTotal: 0,
            failureCategories: []
        )
    }

    static func scanning(runID: UUID) -> Self {
        var value = idle(runID: runID)
        value.stage = .scanning
        return value
    }
}
```

Declare the progress properties as `var` so the factory methods and reporter can build updated immutable snapshots by copying the value. Initialize the store's `latest` with `.idle()`.

Implement `AutomaticTransferProgressStore` as an `@unchecked Sendable` final class protected by `NSLock`. Store `latest` and `[UUID: AsyncStream<AutomaticTransferProgress>.Continuation]`; `updates()` registers a continuation, yields `latest` immediately, and removes the continuation on termination. `publish(_:)` copies continuations under the lock and yields outside the lock.

Implement `AutomaticTransferProgressReporter` as a separate lock-protected final class. Its methods mutate aggregate counters and publish a complete immutable value:

```swift
func beginScanning()
func beginPreparing(currentIndex: Int, knownCount: Int)
func registerPreparedFile(bytes: Int64)
func beginUpload(currentIndex: Int, fileBytes: Int64)
func reportUpload(sent: Int64, total: Int64)
func markVerifying()
func finishCurrentFileUploaded(bytes: Int64)
func finishCurrentFileFailed(category: UploadErrorCategory, bytes: Int64)
func finishRun()
```

Clamp per-file sent bytes to `0...currentBytesTotal`, keep sent bytes monotonic with `max`, and publish `.failed` only as the final stage when `failedCount > 0`; otherwise publish `.completed`.

- [ ] **Step 4: Push GREEN implementation and verify the full suite**

Run:

```powershell
git add App/Sync/AutomaticTransferProgress.swift
git commit -m "feat: add automatic transfer progress state"
git push
$runId = gh run list --branch codex/background-manual-transfer-progress --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $runId --exit-status
```

Expected: all existing tests plus both new tests pass and the unsigned IPA builds.

---

### Task 2: Actual URLSession Upload Byte Events

**Files:**
- Modify: `App/Upload/BackgroundUploadCoordinator.swift`
- Modify: `Tests/DirectUploadCoordinatorTests.swift`
- Modify: test upload fakes in `Tests/PhotoSyncServiceTests.swift` and `Tests/ContentViewModelTests.swift`

**Interfaces:**
- Changes `UploadCoordinating.upload` to accept `onProgress: @escaping @Sendable (Int64, Int64) -> Void`.
- Changes `HTTPFileUploading.upload` to accept the same callback.
- The callback arguments are cumulative body bytes sent and total expected body bytes for the current file.

- [ ] **Step 1: Write a failing coordinator forwarding test**

Add a controlled transport callback and assert it reaches the coordinator before the server completes:

```swift
func testUploadForwardsActualBodyByteProgressBeforeHTTPCompletion() async throws {
    let directory = temporaryDirectory()
    let ledger = try UploadLedger(
        fileURL: directory.appendingPathComponent("ledger.json")
    )
    try await ledger.recordDiscovery(id: "simple-progress", createdAt: .now)
    let credentials = InMemoryCredentialStore()
    try credentials.save("test-secret")
    let transport = ControlledHTTPFileUploader()
    let coordinator = BackgroundUploadCoordinator(
        ledger: ledger,
        credentialStore: credentials,
        transport: transport
    )
    let fileURL = directory.appendingPathComponent("simple.jpg")
    try Data(repeating: 1, count: 10).write(to: fileURL)
    let received = UploadProgressRecorder()

    let upload = Task {
        try await coordinator.upload(assetID: "simple-progress", fileURL: fileURL) {
            sent, total in received.record(sent: sent, total: total)
        }
    }
    await transport.waitUntilStarted()

    await transport.report(sent: 3, total: 10)
    for _ in 0..<200 where received.last?.sent != 3 {
        await Task.yield()
    }

    XCTAssertEqual(received.last?.sent, 3)
    XCTAssertEqual(received.last?.total, 10)
    await transport.succeed(statusCode: 201)
    try await upload.value
}

private final class UploadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (sent: Int64, total: Int64)?

    var last: (sent: Int64, total: Int64)? {
        lock.withLock { value }
    }

    func record(sent: Int64, total: Int64) {
        lock.withLock { value = (sent, total) }
    }
}
```

Update `ControlledHTTPFileUploader`'s wished-for signature to retain and invoke the progress closure.

- [ ] **Step 2: Push RED and verify the signature is missing**

Commit only the test changes, push, and watch CI. Expected: compile failure because neither upload protocol accepts `onProgress`.

- [ ] **Step 3: Implement the delegate transport**

Change the protocols to:

```swift
protocol UploadCoordinating: Sendable {
    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws
    func authenticationBlocked() -> Bool
    func credentialDidChange()
}

extension UploadCoordinating {
    func upload(assetID: String, fileURL: URL) async throws {
        try await upload(assetID: assetID, fileURL: fileURL) { _, _ in }
    }
}
```

Apply the corresponding signature to `HTTPFileUploading`. Replace the private transport struct with a private `NSObject` subclass conforming to `URLSessionDataDelegate` and `URLSessionTaskDelegate`. Keep task state under `NSLock`, keyed by `taskIdentifier`, with response data, continuation, and progress closure. Use:

```swift
func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
) {
    progressHandler(for: task.taskIdentifier)?(
        totalBytesSent,
        totalBytesExpectedToSend
    )
}
```

Accumulate response data in `urlSession(_:dataTask:didReceive:)` and resume the continuation exactly once in `urlSession(_:task:didCompleteWithError:)`. `BackgroundUploadCoordinator` forwards the callback, still validates HTTP status, marks the ledger uploaded only after `2xx`, and then removes the temporary file.

Update all test fakes to the new required signature. Fakes that do not test progress may ignore the closure.

- [ ] **Step 4: Push GREEN and verify**

Commit production and fake signature changes, push, and watch CI. Expected: coordinator progress test and full suite pass.

---

### Task 3: Sequential Automatic Transfer and Aggregate Progress

**Files:**
- Modify: `App/Sync/PhotoSyncService.swift`
- Modify: `Tests/PhotoSyncServiceTests.swift`

**Interfaces:**
- `PhotoSyncService.init` gains `automaticProgressStore: AutomaticTransferProgressStore` with a default fresh store for isolated tests.
- Each `run` creates one `AutomaticTransferProgressReporter` and publishes all automatic stages.
- Candidate uploads are sequential in creation-date order.

- [ ] **Step 1: Replace the old concurrency expectation with a failing serial test**

Use a tracking uploader that increments active count, briefly suspends, then decrements it. Run four matching candidates and assert:

```swift
XCTAssertEqual(uploader.uploadedIDs, ["simple-1", "simple-2", "simple-3", "simple-4"])
XCTAssertEqual(uploader.maximumActiveUploadCount, 1)
```

The current task group implementation should fail with a maximum greater than one.

- [ ] **Step 2: Add a failing aggregate progress test**

Inject a shared store and a fake uploader that reports `5/10`, then `10/10` for two ten-byte files. Subscribe before running and collect until terminal state. Assert the stream contains:

```swift
XCTAssertTrue(values.contains { $0.stage == .uploading && $0.percent == 25 })
XCTAssertEqual(values.last?.stage, .completed)
XCTAssertEqual(values.last?.percent, 100)
XCTAssertEqual(values.last?.uploadedCount, 2)
```

- [ ] **Step 3: Push RED and verify current parallel/no-progress behavior fails**

Commit the two tests, push, and watch CI. Expected: serial assertion fails and progress initializer/API is absent or no upload progress is emitted.

- [ ] **Step 4: Implement sequential preparation and upload**

Remove the `withTaskGroup` candidate upload path. Sort candidates by `creationDate`, export and match them one at a time into a small private `PreparedCandidate` value containing candidate and file URL/size, and register every matched file size with the reporter.

After preparation, iterate the prepared array with an ordinary `for` loop. Before each upload call `beginUpload`; forward the byte callback to `reportUpload`; when sent equals total publish verification; after `upload` returns call `finishCurrentFileUploaded`. On error, retain the existing ledger failure category behavior, call `finishCurrentFileFailed`, remove only that temporary file, and continue the loop.

At run start publish scanning. After the adaptive scans finish, publish the terminal result with `finishRun()`. Keep the existing unique-ID summary aggregation and remove a recovered ID's prior failure category.

- [ ] **Step 5: Push GREEN and verify**

Commit the service changes, push, and watch CI. Expected: serial order, maximum active count one, byte progress, retry recovery, filters, and all prior tests pass.

---

### Task 4: Main-Screen Automatic Progress Card

**Files:**
- Modify: `App/Application/AppDependencies.swift`
- Modify: `App/UI/ContentViewModel.swift`
- Modify: `App/UI/ContentView.swift`
- Modify: `Tests/ContentViewModelTests.swift`

**Interfaces:**
- `ContentViewModel.init` gains `automaticUpdates: @escaping @Sendable () -> AsyncStream<AutomaticTransferProgress>`.
- Publishes `automaticProgress`, `automaticStageTitle`, `automaticByteProgressText`, and `automaticTransferMessage`.
- `AppDependencies` injects the same store into `PhotoSyncService` and `ContentViewModel`.

- [ ] **Step 1: Write a failing replay/display-model test**

Publish an uploading state before constructing the model, inject `store.updates`, and assert after subscription:

```swift
XCTAssertEqual(model.automaticProgress?.percent, 65)
XCTAssertEqual(model.automaticStageTitle, "PC로 자동전송 중 · 2/3장")
XCTAssertEqual(model.automaticByteProgressText, "650바이트 / 1000바이트")
```

Publish a terminal `.failed` value with `[.server]` and assert `automaticTransferMessage == "자동전송 실패 포함 · 서버 오류"`.

- [ ] **Step 2: Push RED and verify view-model API is absent**

Commit the tests, push, and watch CI. Expected: compile failure for the new initializer argument/properties.

- [ ] **Step 3: Implement subscription and display properties**

Follow the existing manual progress subscription pattern with a separate `automaticProgressTask`. Cancel both tasks in `deinit`. Map stages to these stable strings:

```swift
case .idle: "자동전송 대기"
case .scanning: "새 사진 확인 중"
case .preparing: "원본 준비 중 · N/M장"
case .uploading: "PC로 자동전송 중 · N/M장"
case .verifying: "서버 저장 확인 중 · N/M장"
case .completed: "자동전송 완료"
case .failed: "자동전송 완료 · 실패 있음"
```

Reuse the existing byte formatter and `failureCategories.uploadFailureDescription`.

- [ ] **Step 4: Add the SwiftUI card**

Place `automaticStatusCard` between `header` and `manualTransferCard`. During byte transfer show:

```swift
ProgressView(value: Double(progress.percent), total: 100)
Text("\(progress.percent)%")
Text(model.automaticByteProgressText)
```

Also show current/total, completed, and failed counts. Use cyan while active, green on complete, and red when terminal failures exist. When scanning or preparing without known bytes, show an indeterminate `ProgressView`.

- [ ] **Step 5: Wire one shared store and verify GREEN**

Create `automaticProgressStore` once in `AppDependencies.shared`, inject it into the sync service, and pass `{ automaticProgressStore.updates() }` to the content model. Commit, push, and watch CI. Expected: all model and full-suite tests pass and SwiftUI compiles.

---

### Task 5: Build 8, Documentation, and Test QR Publication

**Files:**
- Modify: `project.yml`
- Modify: `README.md`
- Modify: `docs/install.md`
- Replace generated artifact: `C:\Users\user\Desktop\SimpleCameraAutoSender-v0.1.8-test\SimpleCameraAutoSender.ipa`
- Replace generated artifact: `C:\Users\user\Desktop\SimpleCameraAutoSender-v0.1.8-test\install-qr-v0.1.8-build8-test.png`

**Interfaces:**
- Keeps marketing version `0.1.8` and changes `CURRENT_PROJECT_VERSION` from `7` to `8`.
- Keeps test download URL `https://simplecamera-autosender-test.pages.dev/SimpleCameraAutoSender.ipa`.

- [ ] **Step 1: Update build number and user documentation**

Document that automatic photos transfer one at a time and that the main screen shows actual byte progress, current photo number, counts, and failure category. Do not change manual-transfer instructions.

- [ ] **Step 2: Commit and run final CI**

Run:

```powershell
git add project.yml README.md docs/install.md
git commit -m "chore: prepare automatic progress test build"
git push
$runId = gh run list --branch codex/background-manual-transfer-progress --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $runId --exit-status
```

Expected: all tests pass, `TEST SUCCEEDED` appears, and the unsigned IPA artifact uploads.

- [ ] **Step 3: Download and inspect the final IPA**

Download the exact final-run artifact into a unique temporary directory, copy its IPA to the desktop test folder, and inspect `Payload/*.app/Info.plist` with Python `zipfile` and `plistlib`. Expected:

```text
CFBundleShortVersionString=0.1.8
CFBundleVersion=8
```

- [ ] **Step 4: Generate the build-8 QR and deploy Pages**

Encode exactly:

```text
sidestore://install?url=https%3A%2F%2Fsimplecamera-autosender-test.pages.dev%2FSimpleCameraAutoSender.ipa
```

Deploy the two desktop files with Wrangler from the Worker worktree to project `simplecamera-autosender-test`, branch `main`, using the final source commit hash.

- [ ] **Step 5: Verify remote integrity and open only in Chrome**

Download the stable remote IPA to a unique temporary file and compare SHA-256 and size with the desktop IPA. Require exact equality. Open the build-8 QR PNG using `C:\Program Files\Google\Chrome\Application\chrome.exe`; do not open Edge.

- [ ] **Step 6: Final factual handoff**

Report the sequential behavior, actual-byte calculation, error display, test count, version/build, matching SHA-256, local IPA/QR paths, and that Chrome is displaying the QR. Do not tag an official release until real-device transfer is confirmed.
