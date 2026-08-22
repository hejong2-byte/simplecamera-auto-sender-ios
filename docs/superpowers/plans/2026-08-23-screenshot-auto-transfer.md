# Screenshot Auto Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send every unprocessed iPhone screenshot together with eligible Simple Cam photos the next time the existing `Simple Cam이 닫힐 때` automation runs.

**Architecture:** Preserve the single PhotoKit scan and add a trusted `isScreenshot` origin bit to each `PhotoCandidate`. The sync service accepts candidates when that bit is true or, for all other images, when the existing Simple Cam metadata matcher succeeds; the existing ledger, upload coordinator, App Intent identity, and automation remain unchanged.

**Tech Stack:** Swift 5, iOS 17+, PhotoKit, ImageIO, App Intents, XCTest, XcodeGen, GitHub Actions macOS runner.

## Global Constraints

- Use only `PHAssetMediaSubtype.photoScreenshot` to bypass the Simple Cam metadata matcher.
- Keep the Simple Cam rule exactly `6048×8064` or `8064×6048` with no `iPhone` marker in TIFF model or EXIF lens model.
- Never upload ordinary iPhone camera photos, downloaded images, or other unmarked images unless they pass the existing Simple Cam rule.
- Process only assets whose creation date is strictly later than the saved automatic-send baseline.
- Keep `SendNewSimpleCameraPhotosIntent`, bundle identifier `com.hejong2byte.simplecameraautosender`, Keychain identifiers, ledger format, relay endpoint, and existing Shortcuts automation identity.
- Keep the upload count unlimited and let the current coordinator enforce its existing concurrency behavior.
- Do not publish a GitHub Release or replace the SideStore IPA in this implementation plan.
- Follow red-green-refactor for every Swift behavior change.

---

### Task 1: Carry the PhotoKit screenshot subtype into candidates

**Files:**
- Modify: `App/Photos/PhotoAssetSource.swift`
- Test: `Tests/PhotoAssetSourceTests.swift`

**Interfaces:**
- Consumes: `PHAsset.mediaSubtypes: PHAssetMediaSubtype` and `.photoScreenshot`.
- Produces: `PhotoCandidate.init(localIdentifier:creationDate:isScreenshot:)` with `isScreenshot` defaulting to `false`, and `PhotoAssetClassification.isScreenshot(in:) -> Bool`.

- [ ] **Step 1: Write the failing subtype and candidate tests**

Add these tests to `PhotoAssetSourceTests`:

```swift
func testClassifiesOnlyPhotoScreenshotSubtypeAsScreenshot() {
    XCTAssertTrue(PhotoAssetClassification.isScreenshot(in: [.photoScreenshot]))
    XCTAssertTrue(PhotoAssetClassification.isScreenshot(
        in: [.photoScreenshot, .photoHDR]
    ))
    XCTAssertFalse(PhotoAssetClassification.isScreenshot(in: [.photoHDR]))
    XCTAssertFalse(PhotoAssetClassification.isScreenshot(in: []))
}

func testPhotoCandidateDefaultsToOrdinaryImage() {
    let candidate = PhotoCandidate(
        localIdentifier: "ordinary",
        creationDate: .now
    )

    XCTAssertFalse(candidate.isScreenshot)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run on macOS:

```bash
bash scripts/test-ios.sh
```

Expected: compilation fails because `PhotoAssetClassification` and `PhotoCandidate.isScreenshot` do not exist.

- [ ] **Step 3: Add the minimal candidate classification**

Change `PhotoCandidate` and add a focused classifier in `PhotoAssetSource.swift`:

```swift
struct PhotoCandidate: Sendable, Equatable {
    let localIdentifier: String
    let creationDate: Date
    let isScreenshot: Bool

    init(
        localIdentifier: String,
        creationDate: Date,
        isScreenshot: Bool = false
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.isScreenshot = isScreenshot
    }
}

enum PhotoAssetClassification {
    static func isScreenshot(in subtypes: PHAssetMediaSubtype) -> Bool {
        subtypes.contains(.photoScreenshot)
    }
}
```

Populate the new field in `PhotoKitAssetSource.candidates(createdAfter:)`:

```swift
candidates.append(PhotoCandidate(
    localIdentifier: asset.localIdentifier,
    creationDate: creationDate,
    isScreenshot: PhotoAssetClassification.isScreenshot(
        in: asset.mediaSubtypes
    )
))
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
bash scripts/test-ios.sh
```

Expected: all tests pass, including both new `PhotoAssetSourceTests` tests.

- [ ] **Step 5: Commit the candidate classification**

```bash
git add App/Photos/PhotoAssetSource.swift Tests/PhotoAssetSourceTests.swift
git commit -m "feat: classify PhotoKit screenshot candidates"
```

### Task 2: Route screenshots through the existing transfer ledger

**Files:**
- Modify: `App/Sync/PhotoSyncService.swift`
- Test: `Tests/PhotoSyncServiceTests.swift`

**Interfaces:**
- Consumes: `PhotoCandidate.isScreenshot`, `PhotoCandidate.creationDate`, the existing `SimpleCameraMetadataMatching`, `UploadLedger`, and `UploadCoordinating` interfaces.
- Produces: one eligibility rule: `candidate.isScreenshot || metadataMatcher.matches(fileURL:)`, with a strict `candidate.creationDate > baseline` gate before discovery.

- [ ] **Step 1: Write the failing screenshot eligibility test**

Add this test to `PhotoSyncServiceTests`:

```swift
func testUploadsScreenshotWhenSimpleCameraMetadataDoesNotMatch() async throws {
    let ledger = try await makeLedger()
    let source = FakePhotoSource(items: [
        (
            PhotoCandidate(
                localIdentifier: "screenshot-1",
                creationDate: .now,
                isScreenshot: true
            ),
            "Apple Camera"
        ),
        (
            PhotoCandidate(
                localIdentifier: "ordinary-1",
                creationDate: .now
            ),
            "Apple Camera"
        )
    ])
    let uploader = RecordingUploader(ledger: ledger)
    let service = makeService(ledger: ledger, source: source, uploader: uploader)

    let result = try await service.run(trigger: .automation)

    XCTAssertEqual(result.uploaded, 1)
    XCTAssertEqual(uploader.recordedIDs, ["screenshot-1"])
}
```

Add a screenshot-specific retry test:

```swift
func testRetriesFailedScreenshotOnNextAutomationRun() async throws {
    let ledger = try await makeLedger()
    let source = FakePhotoSource(items: [
        (
            PhotoCandidate(
                localIdentifier: "screenshot-retry",
                creationDate: .now,
                isScreenshot: true
            ),
            "not-simple-camera"
        )
    ])
    let credentials = InMemoryCredentialStore()
    try credentials.save("test-secret")
    let uploader = FailOnceUploader(ledger: ledger)
    let service = PhotoSyncService(
        credentialStore: credentials,
        photoSource: source,
        metadataMatcher: TextMetadataMatcher(),
        ledger: ledger,
        uploader: uploader,
        uploadsDirectory: temporaryDirectory(),
        scanDelaysNanoseconds: [0]
    )

    let first = try await service.run(trigger: .automation)
    let second = try await service.run(trigger: .automation)

    XCTAssertEqual(first.failed, 1)
    XCTAssertEqual(second.uploaded, 1)
    XCTAssertEqual(uploader.attemptCount, 2)
}
```

Add this test double next to the existing uploader doubles:

```swift
private final class FailOnceUploader: UploadCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: UploadLedger
    private var attempts = 0

    init(ledger: UploadLedger) {
        self.ledger = ledger
    }

    var attemptCount: Int { lock.withLock { attempts } }

    func upload(assetID: String, fileURL: URL) async throws {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            throw URLError(.notConnectedToInternet)
        }
        try await ledger.markQueued(id: assetID, taskIdentifier: attempt)
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}
```

- [ ] **Step 2: Run the focused suite and verify RED**

Run:

```bash
bash scripts/test-ios.sh
```

Expected: both new tests fail because screenshot candidates do not yet bypass the Simple Cam metadata matcher.

- [ ] **Step 3: Implement the minimal screenshot eligibility branch**

In `PhotoSyncService.transfer(candidate:...)`, replace the single matcher assignment with:

```swift
didMatch = candidate.isScreenshot
    || metadataMatcher.matches(fileURL: fileURL)
```

Do not change `SimpleCameraMetadataMatcher`.

- [ ] **Step 4: Run the suite and verify GREEN**

Run:

```bash
bash scripts/test-ios.sh
```

Expected: all tests pass; the screenshot is uploaded and the ordinary `Apple Camera` image remains excluded.

- [ ] **Step 5: Write the failing strict-baseline test**

Add this test to `PhotoSyncServiceTests`:

```swift
func testSkipsScreenshotsAtOrBeforeAutomaticSendBaseline() async throws {
    let baseline = Date(timeIntervalSince1970: 100)
    let ledger = try UploadLedger(
        fileURL: temporaryDirectory().appendingPathComponent("ledger.json")
    )
    try await ledger.setBaseline(baseline)
    let source = FakePhotoSource(items: [
        (
            PhotoCandidate(
                localIdentifier: "before",
                creationDate: baseline.addingTimeInterval(-1),
                isScreenshot: true
            ),
            "not-simple-camera"
        ),
        (
            PhotoCandidate(
                localIdentifier: "equal",
                creationDate: baseline,
                isScreenshot: true
            ),
            "not-simple-camera"
        ),
        (
            PhotoCandidate(
                localIdentifier: "after",
                creationDate: baseline.addingTimeInterval(1),
                isScreenshot: true
            ),
            "not-simple-camera"
        )
    ])
    let uploader = RecordingUploader(ledger: ledger)
    let service = makeService(ledger: ledger, source: source, uploader: uploader)

    let result = try await service.run(trigger: .automation)

    XCTAssertEqual(result.uploaded, 1)
    XCTAssertEqual(uploader.recordedIDs, ["after"])
    XCTAssertNil(try await ledger.record(id: "before"))
    XCTAssertNil(try await ledger.record(id: "equal"))
}
```

- [ ] **Step 6: Run the suite and verify the baseline test is RED**

Run:

```bash
bash scripts/test-ios.sh
```

Expected: the test fails because `before` and `equal` are uploaded by the fake source despite the baseline.

- [ ] **Step 7: Add the strict baseline gate**

At the start of the candidate loop in `performRun(trigger:)`, before incrementing `discovered`, add:

```swift
guard candidate.creationDate > baseline else {
    continue
}
```

Keep the existing PhotoKit query overlap unchanged so delayed library visibility still works, but never discover or transfer an asset created at or before the baseline.

- [ ] **Step 8: Run the suite and verify GREEN**

Run:

```bash
bash scripts/test-ios.sh
```

Expected: all tests pass; only the `after` screenshot is uploaded.

- [ ] **Step 9: Add accumulated and mixed-candidate coverage**

Add a test that supplies three screenshot candidates, one valid Simple Cam text fixture, and one ordinary image; run the service twice and assert that the first run uploads exactly the four eligible IDs and the second uploads zero:

```swift
func testUploadsAccumulatedScreenshotsAndSimpleCameraPhotoOnlyOnce() async throws {
    let ledger = try await makeLedger()
    let items: [(PhotoCandidate, String)] = (1...3).map { index in
        (
            PhotoCandidate(
                localIdentifier: "screenshot-\(index)",
                creationDate: .now,
                isScreenshot: true
            ),
            "not-simple-camera"
        )
    } + [
        (
            PhotoCandidate(localIdentifier: "simple-1", creationDate: .now),
            "Simple Camera 5.0.7"
        ),
        (
            PhotoCandidate(localIdentifier: "ordinary-1", creationDate: .now),
            "Apple Camera"
        )
    ]
    let source = FakePhotoSource(items: items)
    let uploader = RecordingUploader(ledger: ledger)
    let service = makeService(ledger: ledger, source: source, uploader: uploader)

    let first = try await service.run(trigger: .automation)
    let second = try await service.run(trigger: .automation)

    XCTAssertEqual(first.uploaded, 4)
    XCTAssertEqual(second.uploaded, 0)
    XCTAssertEqual(
        Set(uploader.recordedIDs),
        Set(["screenshot-1", "screenshot-2", "screenshot-3", "simple-1"])
    )
}
```

- [ ] **Step 10: Run the suite and commit the transfer behavior**

Run:

```bash
bash scripts/test-ios.sh
```

Expected: all tests pass with no warnings or failures.

Commit:

```bash
git add App/Sync/PhotoSyncService.swift Tests/PhotoSyncServiceTests.swift
git commit -m "feat: transfer screenshots with Simple Cam photos"
```

### Task 3: Update user-facing scope without breaking the existing automation

**Files:**
- Modify: `App/Automation/SendNewPhotosIntent.swift`
- Modify: `App/UI/ContentView.swift`
- Modify: `README.md`
- Modify: `docs/install.md`
- Modify: `project.yml`
- Test: `Tests/ProjectSmokeTests.swift`

**Interfaces:**
- Consumes: the existing `SendNewSimpleCameraPhotosIntent` type and `openAppWhenRun` behavior.
- Produces: version `0.1.7` / build `5`, screenshot-inclusive copy, and the unchanged App Intent type and title used by the installed personal automation.

- [ ] **Step 1: Strengthen the App Intent identity smoke test**

Keep the existing automation test and add a compile-time construction check without renaming the type:

```swift
func testExistingAutomationIntentTypeRemainsConstructible() {
    _ = SendNewSimpleCameraPhotosIntent()
}
```

- [ ] **Step 2: Run the suite before copy changes**

Run:

```bash
bash scripts/test-ios.sh
```

Expected: all tests pass. This is a characterization test that protects the existing App Intent type during the following edits.

- [ ] **Step 3: Update the in-app descriptions while preserving intent identity**

Keep this declaration unchanged:

```swift
struct SendNewSimpleCameraPhotosIntent: AppIntent
```

Keep the existing title `새 SimpleCamera 사진 전송` so the current Shortcuts action remains recognizable, and change only its description to:

```swift
static let description = IntentDescription(
    "새 Simple Cam 업무사진과 새 스크린샷을 모두 전송합니다."
)
```

Update `ContentView` copy to state:

```swift
Text("Simple Cam으로 찍은 새 사진과 새 스크린샷을 자동으로 전송합니다.")
```

```swift
Text("이 버튼을 누른 시점 이전의 사진은 전송하지 않습니다. 이후 Simple Cam 사진과 스크린샷만 대상입니다.")
```

In the automation card, retain the exact existing automation path and add:

```swift
Text("새 스크린샷은 다음 Simple Cam 종료 때 함께 전송됩니다.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 4: Update README and installation instructions**

Document these exact rules in both `README.md` and `docs/install.md`:

- Existing `Simple Cam이 닫힐 때` automation is unchanged.
- New Simple Cam photos and PhotoKit-marked screenshots are sent together.
- Screenshots wait until the next Simple Cam close; taking a screenshot alone does not wake the sender app.
- Ordinary camera photos and downloaded/saved images remain excluded.
- Every eligible item after the automatic-send baseline is deduplicated by the existing ledger.

- [ ] **Step 5: Bump the app version without changing identity**

Change only these values in `project.yml`:

```yaml
CURRENT_PROJECT_VERSION: 5
MARKETING_VERSION: 0.1.7
```

Update the generated photo permission description to mention both Simple Cam photos and screenshots while leaving `PRODUCT_BUNDLE_IDENTIFIER` unchanged.

- [ ] **Step 6: Verify copy, version, and the full test suite**

Run:

```bash
rg -n "0\.1\.7|스크린샷|Simple Cam이 닫힐 때|SendNewSimpleCameraPhotosIntent" project.yml App README.md docs/install.md Tests/ProjectSmokeTests.swift
bash scripts/test-ios.sh
git diff --check
```

Expected: all new scope text is present, the Intent type remains, all tests pass, and `git diff --check` prints nothing.

- [ ] **Step 7: Commit the UI, documentation, and version**

```bash
git add App/Automation/SendNewPhotosIntent.swift App/UI/ContentView.swift README.md docs/install.md project.yml Tests/ProjectSmokeTests.swift
git commit -m "docs: explain screenshot automatic transfer"
```

### Task 4: Perform final iOS validation and prepare, but do not publish, the IPA

**Files:**
- Verify only: all tracked files
- Generated locally and left untracked/ignored: `SimpleCameraAutoSender.xcodeproj/`, `dist/SimpleCameraAutoSender.ipa`

**Interfaces:**
- Consumes: `scripts/test-ios.sh`, `scripts/build-unsigned-ipa.sh`, the XcodeGen project, and CI workflow `.github/workflows/ci.yml`.
- Produces: a tested unsigned `SimpleCameraAutoSender.ipa` artifact suitable for later SideStore release, without changing the remote release or QR.

- [ ] **Step 1: Run the complete simulator test suite on macOS**

```bash
bash scripts/test-ios.sh
```

Expected: `xcodebuild test` ends with `** TEST SUCCEEDED **` and zero failed tests.

- [ ] **Step 2: Build the unsigned IPA**

```bash
bash scripts/build-unsigned-ipa.sh
```

Expected: `dist/SimpleCameraAutoSender.ipa` exists and the script exits zero.

- [ ] **Step 3: Inspect the IPA package contract**

```bash
unzip -l dist/SimpleCameraAutoSender.ipa | rg "Payload/SimpleCameraAutoSender.app/(Info.plist|SimpleCameraAutoSender)$"
```

Expected: both the app executable and `Info.plist` are listed.

- [ ] **Step 4: Run repository integrity checks**

```bash
git diff --check
git status --short
git log -4 --oneline
```

Expected: no tracked modifications remain; only documented ignored build products may exist; the design, candidate classification, transfer behavior, and copy/version commits are present.

- [ ] **Step 5: Record the release boundary**

Do not create or push a `v0.1.7` tag, do not publish a GitHub Release, and do not replace `docs/install-qr.png` until the user explicitly requests deployment. Preserve branch `codex/screenshot-auto-transfer` for that next step.
