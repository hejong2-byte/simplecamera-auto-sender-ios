# SimpleCamera Auto Sender iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and distribute an iOS app that is invoked when The Simple Camera closes, identifies every new Simple Camera photo from original metadata, and uploads each photo exactly once to the existing relay.

**Architecture:** A SwiftUI application exposes an App Intent used by an iOS personal automation. PhotoKit discovery and ImageIO metadata inspection feed a persistent upload ledger; qualifying originals are queued through a background URLSession and confirmed HTTP successes are recorded. GitHub Actions builds an unsigned IPA, publishes it in GitHub Releases, and generates a stable SideStore installation QR code.

**Tech Stack:** Swift 5.10, SwiftUI, App Intents, PhotoKit, ImageIO, Security/Keychain, background URLSession, XCTest, XcodeGen, GitHub Actions, Python QR generation.

## Global Constraints

- Product name: `SimpleCameraAutoSender`.
- Display name: `SimpleCamera 업무사진 전송`.
- Bundle identifier: `com.hejong2byte.simplecameraautosender`.
- Minimum deployment target: iOS 17.0.
- Repository: public `hejong2-byte/simplecamera-auto-sender-ios` so SideStore can download the release IPA without GitHub authentication.
- Relay endpoint: `https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev/api/shortcut/photos`.
- Upload method: `POST` with original bytes and `Content-Type: application/octet-stream`.
- The relay authorization credential is stored only in iOS Keychain and never committed, logged, placed in workflow configuration, embedded in an IPA, or encoded in the QR code.
- Existing photos are excluded when automatic sending is enabled; only later photos enter the ledger.
- A photo is uploaded only if original ImageIO metadata identifies the TIFF Software product as `Simple Camera`, independent of version number and letter case.
- No application batch-size limit is imposed.
- Successful assets are never uploaded again; failed assets remain retryable.
- The app does not misuse audio, location, or other background modes to simulate permanent residency.

---

## Planned file structure

```text
SimpleCameraAutoSender-iOS/
├── .github/workflows/ci.yml                 # simulator tests and unsigned debug build
├── .github/workflows/release.yml            # tagged unsigned IPA release and QR assets
├── App/
│   ├── Application/
│   │   ├── AppDelegate.swift                # reconnects background URLSession callbacks
│   │   └── SimpleCameraAutoSenderApp.swift  # SwiftUI entry point and dependencies
│   ├── Automation/
│   │   ├── SendNewPhotosIntent.swift        # one action exposed to personal automation
│   │   └── SimpleCameraAppShortcuts.swift   # discoverable App Shortcut
│   ├── Configuration/
│   │   ├── AppConfiguration.swift           # nonsecret relay and monitoring settings
│   │   └── CredentialStore.swift            # Keychain credential access
│   ├── Ledger/
│   │   ├── AssetRecord.swift                # upload state model
│   │   └── UploadLedger.swift               # atomic persistent state actor
│   ├── Photos/
│   │   ├── PhotoAssetSource.swift           # PhotoKit query and original export boundary
│   │   └── SimpleCameraMetadataMatcher.swift# ImageIO TIFF Software inspection
│   ├── Sync/
│   │   └── PhotoSyncService.swift           # single-flight discovery and enqueue orchestration
│   ├── Upload/
│   │   ├── BackgroundUploadCoordinator.swift# background task lifecycle and ledger updates
│   │   └── RelayRequestFactory.swift        # exact HTTP request construction
│   └── UI/
│       ├── ContentView.swift                 # setup/status/recovery screen
│       └── ContentViewModel.swift            # UI state and setup actions
├── App/Resources/Assets.xcassets/            # app icon and accent color
├── Tests/
│   ├── CredentialStoreTests.swift
│   ├── PhotoSyncServiceTests.swift
│   ├── RelayRequestFactoryTests.swift
│   ├── SimpleCameraMetadataMatcherTests.swift
│   └── UploadLedgerTests.swift
├── scripts/build-unsigned-ipa.sh
├── scripts/generate-app-icon.py
├── scripts/generate-install-qr.py
├── scripts/test-ios.sh
├── docs/install.md
├── install-url.txt
├── project.yml
└── README.md
```

---

### Task 1: Create the buildable iOS project and continuous integration baseline

**Files:**
- Create: `project.yml`
- Create: `SimpleCameraAutoSender.xcodeproj/project.pbxproj` through XcodeGen
- Create: `App/Application/SimpleCameraAutoSenderApp.swift`
- Create: `App/Resources/Assets.xcassets/Contents.json`
- Create: `App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `Tests/ProjectSmokeTests.swift`
- Create: `scripts/test-ios.sh`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: no application code.
- Produces: scheme `SimpleCameraAutoSender`; XCTest target `SimpleCameraAutoSenderTests`; iOS 17 application target used by every later task.

- [ ] **Step 1: Write the project smoke test**

```swift
import XCTest
@testable import SimpleCameraAutoSender

final class ProjectSmokeTests: XCTestCase {
    func testBundleIdentifierContract() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.hejong2byte.simplecameraautosender")
    }
}
```

- [ ] **Step 2: Add the minimum application entry point**

```swift
import SwiftUI

enum AppIdentity {
    static let bundleIdentifier = "com.hejong2byte.simplecameraautosender"
}

@main
struct SimpleCameraAutoSenderApp: App {
    var body: some Scene {
        WindowGroup { Text("SimpleCamera 업무사진 전송") }
    }
}
```

- [ ] **Step 3: Define the XcodeGen project**

`project.yml` must declare one iOS application and one unit-test bundle, include `App/**/*.swift`, `App/Resources`, and `Tests/**/*.swift`, set `IPHONEOS_DEPLOYMENT_TARGET: 17.0`, `PRODUCT_BUNDLE_IDENTIFIER: com.hejong2byte.simplecameraautosender`, `SWIFT_VERSION: 5.0`, `GENERATE_INFOPLIST_FILE: YES`, and the full photo-library usage string `Simple Camera로 촬영한 새 업무사진을 찾아 전송하려면 사진 보관함 전체 접근이 필요합니다.`.

- [ ] **Step 4: Add a simulator-selection test script**

```bash
#!/usr/bin/env bash
set -euo pipefail
xcodegen generate
DEVICE_ID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for r in d["devices"].values() for x in r if x["name"].startswith("iPhone")))')"
xcodebuild test \
  -project SimpleCameraAutoSender.xcodeproj \
  -scheme SimpleCameraAutoSender \
  -destination "platform=iOS Simulator,id=${DEVICE_ID}" \
  CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Run the test on a macOS compiler**

Run: `bash scripts/test-ios.sh`

Expected: one passing `ProjectSmokeTests` test and `** TEST SUCCEEDED **`.

Commit the generated `SimpleCameraAutoSender.xcodeproj/project.pbxproj` after generation. Do not commit `xcuserdata`, DerivedData, or simulator state.

- [ ] **Step 6: Add CI and commit**

CI installs XcodeGen with Homebrew and runs `bash scripts/test-ios.sh` on `macos-15` for pushes and pull requests.

```bash
git add project.yml SimpleCameraAutoSender.xcodeproj/project.pbxproj App Tests scripts/test-ios.sh .github/workflows/ci.yml
git commit -m "build: scaffold iOS auto sender"
```

---

### Task 2: Add secure relay configuration

**Files:**
- Create: `App/Configuration/AppConfiguration.swift`
- Create: `App/Configuration/CredentialStore.swift`
- Create: `Tests/CredentialStoreTests.swift`

**Interfaces:**
- Consumes: `AppIdentity.bundleIdentifier`.
- Produces: `AppConfiguration.relayEndpoint: URL`, `CredentialStore` protocol, `KeychainCredentialStore`, and `InMemoryCredentialStore` for tests.

- [ ] **Step 1: Write failing credential and endpoint tests**

```swift
import XCTest
@testable import SimpleCameraAutoSender

final class CredentialStoreTests: XCTestCase {
    func testEndpointIsExistingRelayUploadContract() {
        XCTAssertEqual(
            AppConfiguration.relayEndpoint.absoluteString,
            "https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev/api/shortcut/photos"
        )
    }

    func testInMemoryStoreRoundTripAndClear() throws {
        let store = InMemoryCredentialStore()
        try store.save("secret-value")
        XCTAssertEqual(try store.load(), "secret-value")
        try store.clear()
        XCTAssertNil(try store.load())
    }
}
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `xcodebuild test ... -only-testing:SimpleCameraAutoSenderTests/CredentialStoreTests`

Expected: compile failure because `AppConfiguration` and `CredentialStore` do not exist.

- [ ] **Step 3: Implement the public contract**

```swift
import Foundation

enum AppConfiguration {
    static let relayEndpoint = URL(string:
        "https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev/api/shortcut/photos"
    )!
    static let keychainService = AppIdentity.bundleIdentifier + ".relay"
    static let keychainAccount = "upload-authorization"
}

protocol CredentialStore: Sendable {
    func save(_ value: String) throws
    func load() throws -> String?
    func clear() throws
}
```

Implement `KeychainCredentialStore` with `SecItemAdd`, `SecItemCopyMatching`, and `SecItemDelete`, using accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Trim whitespace and reject an empty value before saving. Never include the stored value in an error description.

- [ ] **Step 4: Run credential tests**

Run: `bash scripts/test-ios.sh`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Configuration Tests/CredentialStoreTests.swift
git commit -m "feat: store relay credential in Keychain"
```

---

### Task 3: Identify only original Simple Camera photos

**Files:**
- Create: `App/Photos/SimpleCameraMetadataMatcher.swift`
- Create: `App/Photos/PhotoAssetSource.swift`
- Create: `Tests/SimpleCameraMetadataMatcherTests.swift`

**Interfaces:**
- Consumes: PhotoKit `PHAsset`, ImageIO metadata.
- Produces: `PhotoCandidate`, `PhotoAssetSourcing`, `PhotoKitAssetSource`, and `SimpleCameraMetadataMatching.matches(fileURL:) -> Bool`.

- [ ] **Step 1: Write metadata-matching tests using generated images**

The test helper creates a 1x1 JPEG with `CGImageDestinationAddImage` and supplies TIFF metadata through `kCGImagePropertyTIFFDictionary` and `kCGImagePropertyTIFFSoftware`.

```swift
func testAcceptsObservedVersionedSoftware() throws {
    let url = try TestImageFactory.jpeg(software: "Simple Camera 5.0.7")
    XCTAssertTrue(SimpleCameraMetadataMatcher().matches(fileURL: url))
}

func testAcceptsFutureVersionAndCase() throws {
    let url = try TestImageFactory.jpeg(software: "simple camera 6.2")
    XCTAssertTrue(SimpleCameraMetadataMatcher().matches(fileURL: url))
}

func testRejectsAppleCameraAndMissingSoftware() throws {
    XCTAssertFalse(SimpleCameraMetadataMatcher().matches(
        fileURL: try TestImageFactory.jpeg(software: "Apple Camera")
    ))
    XCTAssertFalse(SimpleCameraMetadataMatcher().matches(
        fileURL: try TestImageFactory.jpeg(software: nil)
    ))
}
```

- [ ] **Step 2: Run the matcher tests and verify failure**

Expected: compile failure because `SimpleCameraMetadataMatcher` is missing.

- [ ] **Step 3: Implement strict product-name matching**

```swift
import Foundation
import ImageIO

struct SimpleCameraMetadataMatcher: Sendable {
    func matches(fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let software = tiff[kCGImagePropertyTIFFSoftware] as? String else { return false }
        let normalized = software.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "simple camera" || normalized.hasPrefix("simple camera ")
    }
}
```

- [ ] **Step 4: Implement the PhotoKit boundary**

```swift
struct PhotoCandidate: Sendable, Equatable {
    let localIdentifier: String
    let creationDate: Date
}

protocol PhotoAssetSourcing: Sendable {
    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate]
    func exportOriginal(localIdentifier: String, to destination: URL) async throws
}
```

`PhotoKitAssetSource` fetches image assets sorted by creation date ascending. `exportOriginal` finds `.fullSizePhoto` first, then `.photo`, and calls `PHAssetResourceManager.writeData(for:toFile:options:completionHandler:)` through a checked continuation. It never requests the paired video component of a Live Photo.

- [ ] **Step 5: Run tests and commit**

```bash
bash scripts/test-ios.sh
git add App/Photos Tests/SimpleCameraMetadataMatcherTests.swift
git commit -m "feat: detect Simple Camera photo originals"
```

Expected: all tests pass and no user photo fixture exists in the repository.

---

### Task 4: Persist an exactly-once asset ledger

**Files:**
- Create: `App/Ledger/AssetRecord.swift`
- Create: `App/Ledger/UploadLedger.swift`
- Create: `Tests/UploadLedgerTests.swift`

**Interfaces:**
- Consumes: `PhotoCandidate.localIdentifier`.
- Produces: `AssetState`, `AssetRecord`, and actor `UploadLedger` with `baseline()`, `setBaseline(_:)`, `recordDiscovery`, `markIgnored`, `markQueued`, `markUploaded`, `markFailed`, `retryableRecords`, and `reset`.

- [ ] **Step 1: Write ledger state-transition tests**

```swift
func testUploadedAssetCannotReturnToQueued() async throws {
    let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
    try await ledger.recordDiscovery(id: "asset-1", createdAt: .now)
    try await ledger.markQueued(id: "asset-1", taskIdentifier: 7)
    try await ledger.markUploaded(id: "asset-1")
    try await ledger.markQueued(id: "asset-1", taskIdentifier: 8)
    XCTAssertEqual(try await ledger.record(id: "asset-1")?.state, .uploaded)
}

func testFailureRemainsRetryable() async throws {
    let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
    try await ledger.recordDiscovery(id: "asset-2", createdAt: .now)
    try await ledger.markFailed(id: "asset-2", category: .network)
    XCTAssertEqual(try await ledger.retryableRecords().map(\.id), ["asset-2"])
}
```

- [ ] **Step 2: Verify tests fail before implementation**

Expected: compile failure for missing ledger types.

- [ ] **Step 3: Implement Codable state and atomic persistence**

```swift
enum AssetState: String, Codable, Sendable { case discovered, ignored, queued, uploaded, failed }
enum UploadErrorCategory: String, Codable, Sendable { case network, authentication, server, unreadable, unknown }

struct AssetRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    var state: AssetState
    var taskIdentifier: Int?
    var retryCount: Int
    var lastError: UploadErrorCategory?
}
```

`UploadLedger` stores one Codable snapshot in Application Support. Every mutation writes a sibling temporary file using `.atomic`, then replaces the prior snapshot. State transition guards make `.uploaded` and `.ignored` terminal. The serialized file contains no credential or request header.

- [ ] **Step 4: Run tests and commit**

```bash
bash scripts/test-ios.sh
git add App/Ledger Tests/UploadLedgerTests.swift
git commit -m "feat: persist photo upload ledger"
```

---

### Task 5: Queue authenticated background uploads safely

**Files:**
- Create: `App/Upload/RelayRequestFactory.swift`
- Create: `App/Upload/BackgroundUploadCoordinator.swift`
- Create: `App/Application/AppDelegate.swift`
- Create: `Tests/RelayRequestFactoryTests.swift`

**Interfaces:**
- Consumes: `AppConfiguration.relayEndpoint`, credential string, original file URL, `UploadLedger`.
- Produces: `RelayRequestFactory.makeUploadRequest(credential:)`, `UploadCoordinating.enqueue(assetID:fileURL:)`, and `BackgroundUploadCoordinator.shared`.

- [ ] **Step 1: Write exact request-contract tests**

```swift
func testRequestMatchesRelayContract() throws {
    let request = try RelayRequestFactory().makeUploadRequest(credential: "test-secret")
    XCTAssertEqual(request.url, AppConfiguration.relayEndpoint)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-secret")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
    XCTAssertNil(request.httpBody)
}

func testEmptyCredentialIsRejected() {
    XCTAssertThrowsError(try RelayRequestFactory().makeUploadRequest(credential: "  "))
}
```

- [ ] **Step 2: Run request tests and verify failure**

Expected: compile failure for missing factory.

- [ ] **Step 3: Implement request creation and upload interface**

```swift
protocol UploadCoordinating: Sendable {
    func enqueue(assetID: String, fileURL: URL) async throws
    func reconnect() async
}

struct RelayRequestFactory: Sendable {
    func makeUploadRequest(credential: String) throws -> URLRequest {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw UploadConfigurationError.missingCredential }
        var request = URLRequest(url: AppConfiguration.relayEndpoint)
        request.httpMethod = "POST"
        request.setValue(value, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }
}
```

- [ ] **Step 4: Implement background URLSession coordination**

Use identifier `com.hejong2byte.simplecameraautosender.background-upload`, `sessionSendsLaunchEvents = true`, `isDiscretionary = false`, and `waitsForConnectivity = true`. Create upload tasks with `uploadTask(with:fromFile:)`. Store the task identifier before resuming.

Delegate handling must apply these exact categories:

- HTTP 200...299: `.uploaded`, delete temporary file.
- HTTP 401 or 403: `.failed(.authentication)`, do not log the header.
- HTTP 500...599: `.failed(.server)`.
- `URLError`: `.failed(.network)`.
- all other failures: `.failed(.unknown)`.

On the first 401 or 403, set an authentication-blocked flag, cancel outstanding upload tasks that have not started transferring, and mark those assets retryable with `.authentication`. A later credential save clears the flag; automated scans must not enqueue more work while it remains set.

`AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` retains the system completion handler until `urlSessionDidFinishEvents(forBackgroundURLSession:)` calls it on the main actor.

- [ ] **Step 5: Run tests and commit**

```bash
bash scripts/test-ios.sh
git add App/Upload App/Application/AppDelegate.swift Tests/RelayRequestFactoryTests.swift
git commit -m "feat: queue relay uploads in background"
```

---

### Task 6: Orchestrate scans and expose one automation action

**Files:**
- Create: `App/Sync/PhotoSyncService.swift`
- Create: `App/Automation/SendNewPhotosIntent.swift`
- Create: `App/Automation/SimpleCameraAppShortcuts.swift`
- Create: `Tests/PhotoSyncServiceTests.swift`
- Modify: `App/Application/SimpleCameraAutoSenderApp.swift`

**Interfaces:**
- Consumes: `CredentialStore`, `PhotoAssetSourcing`, `SimpleCameraMetadataMatcher`, `UploadLedger`, `UploadCoordinating`.
- Produces: `PhotoSyncService.run(trigger:) async -> SyncEnqueueSummary`, dependency singleton `AppDependencies.shared`, and App Intent `SendNewSimpleCameraPhotosIntent`.

- [ ] **Step 1: Write orchestration tests with fakes**

```swift
func testQueuesEveryNewMatchingPhotoAndIgnoresOthers() async throws {
    let source = FakePhotoSource(items: [
        .init(id: "simple-1", software: "Simple Camera 5.0.7"),
        .init(id: "other-1", software: "Apple Camera"),
        .init(id: "simple-2", software: "Simple Camera 6.0")
    ])
    let uploader = RecordingUploader()
    let service = makeService(source: source, uploader: uploader)
    let result = try await service.run(trigger: .automation)
    XCTAssertEqual(result.queued, 2)
    XCTAssertEqual(await uploader.assetIDs, ["simple-1", "simple-2"])
}

func testSecondInvocationDoesNotQueueUploadedOrQueuedAssetsAgain() async throws {
    let service = makeServiceWithOneMatchingAsset()
    _ = try await service.run(trigger: .automation)
    let second = try await service.run(trigger: .automation)
    XCTAssertEqual(second.queued, 0)
}

func testConcurrentInvocationsCoalesceToOneScan() async throws {
    let source = BlockingPhotoSource()
    let service = makeService(source: source)
    async let first = service.run(trigger: .automation)
    async let second = service.run(trigger: .automation)
    source.release()
    _ = try await (first, second)
    XCTAssertEqual(await source.scanCount, 1)
}

func testMissingCredentialDoesNotExportOrUpload() async {
    let service = makeService(credential: nil)
    await XCTAssertThrowsErrorAsync { try await service.run(trigger: .automation) }
}
```

- [ ] **Step 2: Verify focused tests fail**

Expected: compile failure for `PhotoSyncService` and `SyncEnqueueSummary`.

- [ ] **Step 3: Implement single-flight synchronization**

```swift
enum SyncTrigger: Sendable { case automation, manual, retry }

struct SyncEnqueueSummary: Sendable, Equatable {
    let discovered: Int
    let matched: Int
    let queued: Int
    let failed: Int
}

actor PhotoSyncService {
    func run(trigger: SyncTrigger) async throws -> SyncEnqueueSummary
}
```

The actor reads the baseline and credential first, fetches candidates from `baseline - 60 seconds`, skips terminal and queued ledger records, exports each original to a unique Application Support `Uploads/<asset-id-hash>` file, checks metadata locally, marks nonmatches ignored, and enqueues all matches. It performs discovery passes immediately and after 2 and 5 seconds, coalescing by local identifier, to catch assets still being committed as The Simple Camera closes.

One corrupt item increments `failed` and processing continues. No loop count or batch cap may be added.

- [ ] **Step 4: Add the App Intent and shortcut provider**

```swift
import AppIntents

struct SendNewSimpleCameraPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "새 SimpleCamera 사진 전송"
    static let description = IntentDescription("새로 촬영된 Simple Camera 업무사진을 모두 전송합니다.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = try await AppDependencies.shared.syncService.run(trigger: .automation)
        return .result(dialog: "\(summary.queued)장의 전송을 시작했습니다.")
    }
}
```

`SimpleCameraAppShortcuts` exposes exactly this intent with the Korean short title `새 사진 전송` and system image `paperplane.fill`.

- [ ] **Step 5: Run tests and commit**

```bash
bash scripts/test-ios.sh
git add App/Sync App/Automation App/Application/SimpleCameraAutoSenderApp.swift Tests/PhotoSyncServiceTests.swift
git commit -m "feat: send new photos from app automation"
```

---

### Task 7: Build the one-time setup and recovery UI

**Files:**
- Create: `App/UI/ContentViewModel.swift`
- Create: `App/UI/ContentView.swift`
- Create: `Tests/ContentViewModelTests.swift`
- Modify: `App/Application/SimpleCameraAutoSenderApp.swift`
- Create: `scripts/generate-app-icon.py`
- Create: `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`

**Interfaces:**
- Consumes: `PHPhotoLibrary.authorizationStatus`, `CredentialStore`, `UploadLedger`, `PhotoSyncService`.
- Produces: setup controls and observable `ContentViewModel` state.

- [ ] **Step 1: Write view-model behavior tests**

```swift
func testEnableAutomaticSendingRecordsCurrentBaseline() async throws {
    let clock = FixedClock(now: Date(timeIntervalSince1970: 1234))
    let model = makeViewModel(clock: clock)
    try await model.enableAutomaticSending()
    XCTAssertEqual(try await model.ledger.baseline(), clock.now)
}

func testSaveCredentialNeverPublishesStoredValue() async throws {
    let model = makeViewModel()
    try await model.saveCredential("secret-value")
    XCTAssertTrue(model.hasCredential)
    XCTAssertFalse(String(describing: model).contains("secret-value"))
}
```

- [ ] **Step 2: Implement the setup state machine**

`ContentViewModel` publishes only booleans, counts, dates, and redacted error messages. It provides `requestPhotoAccess()`, `saveCredential(_:)`, `enableAutomaticSending()`, `sendNow()`, `retryFailed()`, and `resetMonitoring()`.

- [ ] **Step 3: Implement the SwiftUI screen**

The screen order is fixed:

1. **사진 접근** with status and grant button.
2. **전송 인증 설정** with `SecureField` and save button.
3. **자동 전송 시작** with an explicit historical-photo exclusion explanation.
4. **아이폰 자동화 1회 설정** showing `앱 → The Simple Camera → 닫힐 때 → 새 SimpleCamera 사진 전송 → 즉시 실행`.
5. Status counts and last error.
6. **지금 전송**, **실패 재시도**, and confirmed **자동 전송 초기화**.

The credential field is cleared immediately after a successful save.

- [ ] **Step 4: Generate a deterministic app icon**

`scripts/generate-app-icon.py` uses Pillow to create a 1024x1024 opaque navy background, a centered white camera outline, and a cyan upward arrow. It writes only `AppIcon-1024.png`; Xcode generates derived sizes from the single marketing image.

- [ ] **Step 5: Run tests and commit**

```bash
python3 scripts/generate-app-icon.py
bash scripts/test-ios.sh
git add App/UI App/Application App/Resources Tests/ContentViewModelTests.swift scripts/generate-app-icon.py
git commit -m "feat: add automatic sending setup UI"
```

---

### Task 8: Package the SideStore IPA and installation QR

**Files:**
- Create: `scripts/build-unsigned-ipa.sh`
- Create: `scripts/generate-install-qr.py`
- Create: `install-url.txt`
- Create: `.github/workflows/release.yml`
- Create: `README.md`
- Create: `docs/install.md`
- Create: `docs/install-qr.png`

**Interfaces:**
- Consumes: Xcode scheme `SimpleCameraAutoSender`, GitHub repository and release asset URL.
- Produces: `dist/SimpleCameraAutoSender.ipa`, stable SideStore URI, PNG QR code, tagged GitHub Release.

- [ ] **Step 1: Add the stable SideStore URI**

`install-url.txt` contains exactly one line:

```text
sidestore://install?url=https%3A%2F%2Fgithub.com%2Fhejong2-byte%2Fsimplecamera-auto-sender-ios%2Freleases%2Flatest%2Fdownload%2FSimpleCameraAutoSender.ipa
```

- [ ] **Step 2: Write QR payload tests**

`scripts/generate-install-qr.py --check` must parse `install-url.txt`, assert scheme `sidestore`, host `install`, query key `url`, HTTPS decoded host `github.com`, expected account/repository, and asset name `SimpleCameraAutoSender.ipa`. It exits nonzero for any mismatch.

- [ ] **Step 3: Implement unsigned IPA packaging**

```bash
#!/usr/bin/env bash
set -euo pipefail
xcodegen generate
rm -rf build dist Payload
xcodebuild build \
  -project SimpleCameraAutoSender.xcodeproj \
  -scheme SimpleCameraAutoSender \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
mkdir -p Payload dist
cp -R build/Build/Products/Release-iphoneos/SimpleCameraAutoSender.app Payload/
ditto -c -k --sequesterRsrc --keepParent Payload dist/SimpleCameraAutoSender.ipa
test -s dist/SimpleCameraAutoSender.ipa
unzip -t dist/SimpleCameraAutoSender.ipa
```

- [ ] **Step 4: Generate and validate the QR**

The Python script uses `qrcode[pil]`, error correction level H, no analytics or URL shortener, and creates `docs/install-qr.png`. The QR payload is the literal content of `install-url.txt`.

Run:

```bash
python3 -m pip install 'qrcode[pil]'
python3 scripts/generate-install-qr.py --check
python3 scripts/generate-install-qr.py --output docs/install-qr.png
```

Expected: payload validation succeeds and the PNG decodes to the exact SideStore URI.

- [ ] **Step 5: Add release automation**

`.github/workflows/release.yml` triggers on `v*` tags, runs all tests, builds the unsigned IPA, regenerates the QR, verifies the IPA ZIP, creates a GitHub Release with `softprops/action-gh-release`, and uploads both `SimpleCameraAutoSender.ipa` and `install-qr.png`. Workflow permission is only `contents: write`; no secret other than GitHub's scoped `GITHUB_TOKEN` is used.

- [ ] **Step 6: Document installation and automation setup**

README displays `docs/install-qr.png`, provides a clickable SideStore URI, explains that SideStore performs device signing and seven-day refresh, and links `docs/install.md`. The install guide includes the one-time photo permission, credential save, baseline enablement, and personal automation sequence.

- [ ] **Step 7: Run checks and commit**

```bash
python3 scripts/generate-install-qr.py --check
bash scripts/test-ios.sh
bash scripts/build-unsigned-ipa.sh
git add .github README.md docs install-url.txt scripts
git commit -m "build: publish SideStore IPA and QR installer"
```

Expected: tests pass, IPA ZIP validation passes, and QR payload check passes.

---

### Task 9: Publish and verify the complete GitHub delivery

**Files:**
- Modify only if verification exposes a defect in files created by Tasks 1-8.

**Interfaces:**
- Consumes: local `main` branch and GitHub account `hejong2-byte`.
- Produces: public repository, green CI, tagged release, downloadable IPA, and working SideStore QR.

- [ ] **Step 1: Perform a secret scan before publication**

Run repository searches for `Authorization`, `Bearer`, credential values, local settings paths, `.p12`, `.mobileprovision`, and private keys. The only allowed authorization occurrence is code that sets the header from a runtime Keychain value and tests using the literal `test-secret`.

Expected: no real relay credential and no signing material found.

- [ ] **Step 2: Create the public GitHub repository**

Create `hejong2-byte/simplecamera-auto-sender-ios` as a public repository with no generated README, license, or gitignore because those files already exist locally. Use the authenticated GitHub account shown by the user; never request or expose a password or personal access token in chat.

- [ ] **Step 3: Push and verify CI**

```bash
git remote add origin https://github.com/hejong2-byte/simplecamera-auto-sender-ios.git
git push -u origin main
```

Expected: the `CI` workflow completes successfully and its logs contain no credential.

- [ ] **Step 4: Tag and verify release**

```bash
git tag -a v0.1.0 -m "SimpleCamera Auto Sender v0.1.0"
git push origin v0.1.0
```

Expected: the release workflow succeeds and this URL returns an IPA ZIP:

```text
https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/latest/download/SimpleCameraAutoSender.ipa
```

- [ ] **Step 5: Verify QR and SideStore handoff**

Decode the published QR and confirm it matches `install-url.txt`. On the user's iPhone, scan the QR and confirm SideStore opens an installation prompt for `SimpleCamera 업무사진 전송`.

- [ ] **Step 6: Run the device acceptance sequence**

1. Install, grant full photo access, save the runtime credential, and enable monitoring.
2. Create the The Simple Camera close automation with immediate execution.
3. Take one Simple Camera photo and leave the app; confirm one relay/PC delivery.
4. Take multiple photos and a long burst; confirm every matching image arrives exactly once.
5. Take an Apple Camera photo and screenshot; confirm neither is uploaded.
6. Disable the network, take photos, leave The Simple Camera, restore the network, and confirm retry delivery.
7. Trigger the automation twice and confirm no duplicate PC files.

- [ ] **Step 7: Record verified release and commit documentation corrections**

If device-specific wording differs from the install guide, update only `docs/install.md` and README with the observed labels, rerun the QR check, and commit:

```bash
git add README.md docs/install.md
git commit -m "docs: confirm SideStore device setup"
git push origin main
```

Completion requires green CI, a downloadable release IPA, a QR that opens SideStore, and the device acceptance sequence. A successful simulator build alone is not completion.
