# All New Photos Auto Send Implementation Plan (폐기됨)

> 이 계획은 사용자의 최종 요구사항과 달라 실행하지 않는다. Simple Cam 사진만 전송하는 `2026-08-22-simple-cam-resolution-origin-filter-design.md`를 기준으로 새 구현 계획을 사용한다.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Simple Cam-only metadata filter and Shortcuts dependency with an iPhone app that sends every image added after the user starts the new mode.

**Architecture:** Keep the existing PhotoKit discovery, persistent ledger, and background URLSession upload pipeline. Introduce a versioned all-photo baseline, scan all new image assets without metadata matching, observe PhotoKit while the app is alive, scan whenever the app becomes active, and request opportunistic `BGAppRefreshTask` runs. iOS may delay background work, so foreground re-entry always performs catch-up.

**Tech Stack:** Swift 5, SwiftUI, PhotoKit, BackgroundTasks, background URLSession, XCTest, XcodeGen, GitHub Actions, SideStore unsigned IPA.

## Global Constraints

- Deployment target remains iOS 17.0.
- The bundle identifier remains `com.hejong2byte.simplecameraautosender` so upgrades keep the app container and Keychain credential.
- Only images added after `지금부터 모든 새 사진 전송` is pressed are eligible.
- General Camera photos, Simple Cam photos, screenshots, and downloaded or saved images are all eligible.
- TIFF `Software` metadata is not read and App Intents/Shortcuts are not required.
- Each `PHAsset.localIdentifier` uploads at most once.
- Existing relay URL, Authorization format, PC receiver protocol, and credential storage remain unchanged.
- Background scanning is best effort; foreground activation always catches up.

---

### Task 1: Versioned all-photo ledger and metadata-free sync

**Files:**
- Modify: `App/Ledger/UploadLedger.swift`
- Modify: `App/Photos/PhotoAssetSource.swift`
- Modify: `App/Sync/PhotoSyncService.swift`
- Modify: `App/Application/AppDependencies.swift`
- Modify: `Tests/UploadLedgerTests.swift`
- Modify: `Tests/PhotoSyncServiceTests.swift`
- Delete: `App/Photos/SimpleCameraMetadataMatcher.swift`
- Delete: `Tests/SimpleCameraMetadataMatcherTests.swift`

**Interfaces:**
- Produces: `UploadLedger.startAllPhotos(at:)`, `UploadLedger.allPhotosBaseline()`, and `PhotoSyncService.run(trigger:)` with `SyncEnqueueSummary(discovered:queued:failed:)`.
- Consumes: existing `PhotoAssetSourcing`, `UploadCoordinating`, `AssetRecord`, and background uploader.

- [ ] **Step 1: Add failing ledger migration tests**

```swift
func testOldLedgerIsNotEnabledForAllPhotosMode() async throws {
    let url = temporaryLedgerURL()
    try #"{"baseline":0,"records":{}}"#.data(using: .utf8)!.write(to: url)
    let ledger = try UploadLedger(fileURL: url)
    XCTAssertNil(try await ledger.allPhotosBaseline())
}

func testStartingAllPhotosUsesNowAndClearsOldRecords() async throws {
    let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
    try await ledger.recordDiscovery(id: "old", createdAt: .distantPast)
    let start = Date(timeIntervalSince1970: 1_234)
    try await ledger.startAllPhotos(at: start)
    XCTAssertEqual(try await ledger.allPhotosBaseline(), start)
    XCTAssertTrue(await ledger.allRecords().isEmpty)
}
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `xcodegen generate && xcodebuild test -project SimpleCameraAutoSender.xcodeproj -scheme SimpleCameraAutoSender -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SimpleCameraAutoSenderTests/UploadLedgerTests`

Expected: compilation fails because `allPhotosBaseline` and `startAllPhotos` do not exist.

- [ ] **Step 3: Add an optional persisted mode and the new baseline methods**

```swift
private enum MonitoringMode: String, Codable { case allPhotosV1 }

private struct Snapshot: Codable {
    var baseline: Date?
    var records: [String: AssetRecord]
    var monitoringMode: MonitoringMode?
}

func allPhotosBaseline() -> Date? {
    snapshot.monitoringMode == .allPhotosV1 ? snapshot.baseline : nil
}

func startAllPhotos(at date: Date) throws {
    snapshot.baseline = date
    snapshot.monitoringMode = .allPhotosV1
    snapshot.records = [:]
    try persist()
}
```

Keep decoding compatible with old snapshots by making `monitoringMode` optional.

- [ ] **Step 4: Add failing sync tests for all image types and no duplicates**

```swift
func testQueuesEveryNewImageWithoutInspectingMetadata() async throws {
    let source = FakePhotoSource(items: [
        PhotoCandidate(localIdentifier: "camera", creationDate: .now),
        PhotoCandidate(localIdentifier: "simple-cam", creationDate: .now),
        PhotoCandidate(localIdentifier: "screenshot", creationDate: .now)
    ])
    let result = try await makeService(source: source).run(trigger: .manual)
    XCTAssertEqual(result.discovered, 3)
    XCTAssertEqual(result.queued, 3)
}
```

Retain and adapt the existing second-invocation test to assert that all three identifiers are queued only once.

- [ ] **Step 5: Replace the PhotoKit predicate with an in-memory recent-image cutoff**

```swift
let options = PHFetchOptions()
options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
let result = PHAsset.fetchAssets(with: .image, options: options)
var candidates: [PhotoCandidate] = []
result.enumerateObjects { asset, _, stop in
    guard let creationDate = asset.creationDate else { return }
    guard creationDate > date else {
        stop.pointee = true
        return
    }
    candidates.append(.init(localIdentifier: asset.localIdentifier, creationDate: creationDate))
}
return candidates.sorted { $0.creationDate < $1.creationDate }
```

This avoids the former combined PhotoKit predicate and still stops as soon as the sorted result reaches the baseline.

- [ ] **Step 6: Remove the metadata matcher from `PhotoSyncService`**

```swift
struct SyncEnqueueSummary: Sendable, Equatable {
    let discovered: Int
    let queued: Int
    let failed: Int
}

try await photoSource.exportOriginal(localIdentifier: candidate.localIdentifier, to: fileURL)
try await uploader.enqueue(assetID: candidate.localIdentifier, fileURL: fileURL)
queued += 1
```

Use `ledger.allPhotosBaseline()`, never mark images ignored, and leave export failures retryable. Remove the matcher dependency and its tests/files.

- [ ] **Step 7: Run all iOS tests**

Run: `bash scripts/test-ios.sh`

Expected: every test passes and the target compiles without `SimpleCameraMetadataMatcher`.

- [ ] **Step 8: Commit Task 1**

```bash
git add App/Ledger App/Photos App/Sync App/Application Tests
git commit -m "feat: send every new photo without metadata filtering"
```

---

### Task 2: Independent foreground observer and background refresh

**Files:**
- Create: `App/Monitoring/PhotoLibraryMonitor.swift`
- Create: `App/Monitoring/PhotoRuntimeCoordinator.swift`
- Modify: `App/Application/AppDelegate.swift`
- Modify: `App/Application/AppDependencies.swift`
- Modify: `App/Application/SimpleCameraAutoSenderApp.swift`
- Modify: `project.yml`
- Create: `Tests/PhotoRuntimeCoordinatorTests.swift`

**Interfaces:**
- Consumes: `PhotoSyncService.run(trigger:)`.
- Produces: `PhotoLibraryMonitor.start()`, `PhotoRuntimeCoordinator.start()`, `becameActive()`, `enteredBackground()`, and `handleBackgroundRefresh(_:)`.

- [ ] **Step 1: Write failing coordinator tests**

```swift
func testStartObservesAndPerformsForegroundCatchUp() async {
    let scanner = RecordingScanner()
    let observer = RecordingPhotoObserver()
    let coordinator = PhotoRuntimeCoordinator(scanner: scanner, observer: observer, scheduler: NoOpScheduler())
    coordinator.start()
    await coordinator.becameActive()
    XCTAssertEqual(observer.startCount, 1)
    XCTAssertEqual(scanner.triggers, [.foreground])
}

func testPhotoChangeStartsLibraryChangeScan() async {
    let fixture = makeCoordinator()
    fixture.coordinator.start()
    fixture.observer.emitChange()
    await fixture.scanner.waitForScan()
    XCTAssertEqual(fixture.scanner.triggers, [.libraryChange])
}
```

- [ ] **Step 2: Run the focused test and confirm compilation failure**

Run: `xcodegen generate && xcodebuild test -project SimpleCameraAutoSender.xcodeproj -scheme SimpleCameraAutoSender -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SimpleCameraAutoSenderTests/PhotoRuntimeCoordinatorTests`

Expected: compilation fails because the monitoring types do not exist.

- [ ] **Step 3: Implement the PhotoKit observer**

```swift
final class PhotoLibraryMonitor: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var isStarted = false

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func start() {
        guard !isStarted else { return }
        isStarted = true
        PHPhotoLibrary.shared().register(self)
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
    deinit { if isStarted { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }
}
```

- [ ] **Step 4: Implement the runtime coordinator and background task registration**

Use identifier `com.hejong2byte.simplecameraautosender.refresh`. Register a `BGAppRefreshTask` during app launch, reschedule after each run, cancel its Swift `Task` in the expiration handler, and call `setTaskCompleted(success:)` only after the scan returns.

```swift
enum SyncTrigger: Sendable { case foreground, libraryChange, background, manual, retry }

func becameActive() async { _ = try? await scanner.run(trigger: .foreground) }
func photoLibraryChanged() { Task { _ = try? await scanner.run(trigger: .libraryChange) } }
func enteredBackground() { scheduler.schedule(earliest: Date().addingTimeInterval(15 * 60)) }
```

- [ ] **Step 5: Wire the lifecycle without Shortcuts**

Register background refresh in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`. In `SimpleCameraAutoSenderApp`, observe `scenePhase`: call `start()` once, `becameActive()` for `.active`, and `enteredBackground()` for `.background`.

Add generated Info.plist values in `project.yml`:

```yaml
INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers:
  - com.hejong2byte.simplecameraautosender.refresh
INFOPLIST_KEY_UIBackgroundModes:
  - fetch
```

- [ ] **Step 6: Run coordinator tests and the full suite**

Run: `bash scripts/test-ios.sh`

Expected: coordinator tests and all existing tests pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add App/Monitoring App/Application project.yml Tests/PhotoRuntimeCoordinatorTests.swift
git commit -m "feat: monitor new photos without shortcuts"
```

---

### Task 3: Replace Simple Cam UI and remove App Intents

**Files:**
- Modify: `App/UI/ContentView.swift`
- Modify: `App/UI/ContentViewModel.swift`
- Modify: `Tests/ContentViewModelTests.swift`
- Modify: `Tests/ProjectSmokeTests.swift`
- Delete: `App/Automation/SendNewPhotosIntent.swift`
- Delete: `App/Automation/SimpleCameraAppShortcuts.swift`
- Modify: `README.md`
- Modify: `docs/install.md`

**Interfaces:**
- Consumes: `UploadLedger.startAllPhotos(at:)`, runtime scans, and `SyncEnqueueSummary(discovered:queued:failed:)`.
- Produces: setup UI labeled `지금부터 모든 새 사진 전송`, status text with 발견/전송/실패 counts, and `지금 확인`.

- [ ] **Step 1: Write failing view-model and smoke tests**

```swift
func testStartAllPhotosRecordsCurrentTimeAndEnablesMonitoring() async throws {
    try await model.startAllPhotos()
    XCTAssertEqual(try await ledger.allPhotosBaseline(), expectedNow)
    XCTAssertTrue(model.isMonitoringEnabled)
}

func testProjectContainsNoAppIntentOrMetadataMatcher() throws {
    XCTAssertFalse(sourceText.contains("SendNewSimpleCameraPhotosIntent"))
    XCTAssertFalse(sourceText.contains("SimpleCameraMetadataMatcher"))
}
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `bash scripts/test-ios.sh`

Expected: tests fail on old method names and remaining App Intent/metadata references.

- [ ] **Step 3: Update the UI and model**

Rename `enableAutomaticSending()` to `startAllPhotos()`, call `ledger.startAllPhotos(at: now())`, and update the screen copy:

```swift
Text("지금부터 사진함에 새로 추가되는 모든 이미지를 전송합니다.")
Button("지금부터 모든 새 사진 전송") { Task { try? await model.startAllPhotos() } }
Text("최근 확인: 발견 \(summary.discovered)장 · 전송 시작 \(summary.queued)장 · 실패 \(summary.failed)장")
Button("지금 확인") { Task { await model.sendNow() } }
```

Remove the automation setup card. Keep photo permission, credential, current counts, retry, and reset controls.

- [ ] **Step 4: Delete App Intent files and update user documentation**

Document that no Shortcuts automation is required, foreground monitoring is immediate while the app is alive, and iOS may postpone scans while the app is suspended. Do not claim guaranteed permanent background residence.

- [ ] **Step 5: Run tests and an unsigned IPA smoke build**

Run: `bash scripts/test-ios.sh && bash scripts/build-unsigned-ipa.sh && unzip -t dist/SimpleCameraAutoSender.ipa`

Expected: tests pass; IPA exists; ZIP integrity reports no errors; compiled app contains the app icon.

- [ ] **Step 6: Commit Task 3**

```bash
git add App/UI App/Automation Tests README.md docs/install.md
git commit -m "feat: present independent all-photo sender"
```

---

### Task 4: Version, publish, and verify the SideStore installer

**Files:**
- Modify: `project.yml`
- Modify: `README.md`
- Regenerate: `docs/install-qr.png`

**Interfaces:**
- Produces: GitHub Release `v0.2.0`, asset `SimpleCameraAutoSender.ipa`, and the stable latest-release SideStore QR.

- [ ] **Step 1: Set version 0.2.0 and validate project generation**

```yaml
MARKETING_VERSION: 0.2.0
CURRENT_PROJECT_VERSION: 2
```

Run: `xcodegen generate && git diff --check`

Expected: generated project contains version 0.2.0 and no whitespace errors.

- [ ] **Step 2: Push main and wait for CI**

Run: `git push origin main && gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status`

Expected: tests and unsigned IPA build succeed.

- [ ] **Step 3: Tag and publish**

Run:

```bash
git tag -a v0.2.0 -m "All new photos auto sender v0.2.0"
git push origin v0.2.0
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

Expected: release workflow succeeds and publishes both release assets.

- [ ] **Step 4: Verify published assets and QR target**

Run:

```bash
gh release view v0.2.0 --repo hejong2-byte/simplecamera-auto-sender-ios --json assets,tagName,url
python scripts/generate-install-qr.py --check
```

Expected: `SimpleCameraAutoSender.ipa` and `install-qr.png` are present; the QR resolves to `releases/latest/download/SimpleCameraAutoSender.ipa`.

- [ ] **Step 5: Copy the released IPA and QR for delivery**

Download the exact release asset, verify its SHA-256 against GitHub's asset digest, copy the IPA to `C:\Users\user\Desktop\SimpleCameraAutoSender-v0.2.0.ipa`, and provide the released QR image to the user.

- [ ] **Step 6: Final device acceptance test**

On the iPhone: install with SideStore, grant full photo access, confirm the credential, press `지금부터 모든 새 사진 전송`, then create one Camera photo and one screenshot. With the app active, both must appear as discovered and queued exactly once; after PC receipt, the completion count must become 2.
