# Full-Screen Receive Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iPhone app use the full safe-area height and always show an understandable, durable PC receive result.

**Architecture:** Add a launch-screen declaration at the generated Info.plist boundary, compact only the redundant main-screen presentation, and introduce one receiver-scoped atomic JSON record for the latest terminal receive outcome. `USBReceiverViewModel` combines active progress, the durable outcome, and idle registration state into one UI-neutral status value consumed by both the main and detailed receiver screens.

**Tech Stack:** Swift 5, SwiftUI, Foundation Codable/atomic file writes, XCTest/XCUITest, XcodeGen, GitHub Actions macOS CI.

## Global Constraints

- Deployment target remains iOS 17.0 and device family remains iPhone.
- Preserve safe areas, Dynamic Type, and normal button tap targets.
- Do not change relay endpoints, Windows sender routing, registration codes, USB bookmarks, authentication storage, or file integrity rules.
- Do not store secrets, file contents, or USB bookmarks in the new status file.
- A corrupt status file must not block file reception.
- Closed-app push notifications are out of scope.
- Physical Lightning/USB behavior cannot be claimed from simulator tests.

---

### Task 1: Restore full-screen presentation and compact the main screen

**Files:**
- Modify: `project.yml`
- Modify: `App/UI/ContentView.swift`
- Modify: `Tests/ProjectSmokeTests.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`

**Interfaces:**
- Consumes: the existing `ContentView` navigation and cards.
- Produces: a generated app Info.plist containing `UILaunchScreen`, and accessibility identifiers for the three manual actions and receiver entry.

- [ ] **Step 1: Write failing launch-screen and compact-layout contract tests**

Add to `Tests/ProjectSmokeTests.swift`:

```swift
func testReleaseDeclaresModernLaunchScreen() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let project = try String(
        contentsOf: repository.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    XCTAssertTrue(project.contains("UILaunchScreen: {}"))
}

func testMainScreenDoesNotKeepTheRedundantDecorativeHeader() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
        contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
        encoding: .utf8
    )
    XCTAssertFalse(source.contains("private var header: some View"))
    XCTAssertFalse(source.contains("header\n"))
}
```

Add an XCUITest that launches the simulator without scrolling and requires
`manual-photo`, `manual-screenshot`, `manual-video`, and `open-receiver` to be
hittable. Keep an attachment named `main-fullscreen-compact`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run on macOS CI:

```bash
./scripts/test-ios.sh
```

Expected: the launch-screen/header contracts and initial-screen hit testing fail because the key and identifiers do not exist and the redundant header still consumes height.

- [ ] **Step 3: Add the launch declaration and compact only redundant content**

Under `targets.SimpleCameraAutoSender.info.properties` in `project.yml`, add:

```yaml
        UILaunchScreen: {}
```

In `ContentView`, remove the standalone 64-point arrow/header and its duplicate explanation. Change the root card stack spacing from 16 to 12 and use horizontal 16 / vertical 12 padding. Keep `manualStatusCard` visible only when manual progress or a manual summary exists. Assign these identifiers:

```swift
.accessibilityIdentifier("manual-\(kind.rawValue)")
```

Because `ManualMediaKind.rawValue` is exactly `photo`, `screenshot`, or `video`,
the interpolation produces the stable identifiers `manual-photo`,
`manual-screenshot`, and `manual-video`. Assign `open-receiver` to the PC
receive navigation link.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

Run `./scripts/test-ios.sh`. Expected: all unit and UI tests pass, with the four initial-screen controls hittable on the selected iPhone simulator and a screenshot retained.

- [ ] **Step 5: Commit**

```bash
git add project.yml App/UI/ContentView.swift Tests/ProjectSmokeTests.swift UITests/ForegroundReceiveUITests.swift
git commit -m "fix: restore full-screen iPhone layout"
```

---

### Task 2: Persist one receiver-scoped terminal outcome

**Files:**
- Create: `App/Receive/IPhoneReceiveOutcome.swift`
- Create: `Tests/IPhoneReceiveOutcomeStoreTests.swift`
- Modify: `App/Application/USBReceiverDependencies.swift`

**Interfaces:**
- Consumes: `IPhoneReceiveDestination`, `USBReceiveProgress`, and the current registered receiver UUID.
- Produces: `IPhoneReceiveOutcome`, `IPhoneReceiveOutcomeStore.load(receiverID:)`, `save(_:)`, and `clear(receiverID:)`.

- [ ] **Step 1: Write failing persistence tests**

Cover all of these with a temporary file:

```swift
func testSavedOutcomeSurvivesStoreRecreation() throws
func testOutcomeIsHiddenFromAnotherReceiver() throws
func testLaterSuccessReplacesFailure() throws
func testCorruptStatusFailsClosed() throws
func testClearOnlyRemovesMatchingReceiver() throws
```

Use fixed receiver UUIDs and dates. Assert complete equality after a new store
instance reads the file, and assert `nil` for corrupt JSON or a different
receiver.

- [ ] **Step 2: Run tests and verify RED**

Run the suite in macOS CI. Expected: compilation fails because
`IPhoneReceiveOutcomeStore` does not exist.

- [ ] **Step 3: Implement the minimal atomic store**

Create domain types with these signatures:

```swift
enum IPhoneReceiveOutcomeKind: String, Codable, Sendable, Equatable {
    case saved
    case failed
}

struct IPhoneReceiveOutcome: Codable, Sendable, Equatable {
    let receiverID: UUID
    let kind: IPhoneReceiveOutcomeKind
    let destination: IPhoneReceiveDestination
    let fileName: String?
    let totalCount: Int
    let completedCount: Int
    let message: String
    let occurredAt: Date
}

final class IPhoneReceiveOutcomeStore: @unchecked Sendable {
    init(fileURL: URL, fileManager: FileManager = .default)
    func load(receiverID: UUID) -> IPhoneReceiveOutcome?
    func save(_ outcome: IPhoneReceiveOutcome) throws
    func clear(receiverID: UUID) throws
}
```

Encode `{ version: 1, outcome: ... }`, create the parent directory, and write
with `.atomic`. Protect access with `NSLock`. `load` catches missing/corrupt data
and returns `nil`. `clear` removes the file only when the decoded record belongs
to the supplied receiver.

In `USBReceiverDependencies`, create the store at:

```swift
stateDirectory.appendingPathComponent("latest-receive-outcome.json")
```

Pass store closures into the receiver view model without changing any existing
ledger, job, approval, or catalog path.

- [ ] **Step 4: Run tests and verify GREEN**

Run `./scripts/test-ios.sh`. Expected: the new store tests and all existing data-path stability tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Receive/IPhoneReceiveOutcome.swift Tests/IPhoneReceiveOutcomeStoreTests.swift App/Application/USBReceiverDependencies.swift
git commit -m "feat: persist latest PC receive result"
```

---

### Task 3: Derive one clear receive status in the view model

**Files:**
- Modify: `App/UI/USBReceiverViewModel.swift`
- Modify: `Tests/USBReceiverViewModelTests.swift`

**Interfaces:**
- Consumes: Task 2 load/save/clear closures and `USBReceiveProgress` updates.
- Produces: `IPhoneReceiveStatus` through `USBReceiverViewModel.receiveStatus`.

- [ ] **Step 1: Write failing view-model tests**

Define assertions for:

```swift
func testIdleDoesNotEraseLastSavedOutcome() async throws
func testActiveProgressTemporarilyOverridesSavedOutcome() async throws
func testCompletionPersistsFileDestinationCountAndTime() async throws
func testFailurePersistsCategorizedMessageAndTime() async throws
func testLaterSuccessReplacesPersistedFailure() async throws
func testRegistrationResetClearsTheMatchingOutcome() async throws
func testOutcomeFromAnotherReceiverIsNotPresented() async throws
```

Use an in-memory outcome harness plus a fixed `now` closure. Verify that a
discovery failure with no delivery ID is titled `새 파일 확인 오류`, while a
file failure is titled `iPhone 수신 오류` or `USB 수신 오류`.

- [ ] **Step 2: Run tests and verify RED**

Run `./scripts/test-ios.sh`. Expected: compilation fails because
`receiveStatus` and the injected outcome operations do not exist.

- [ ] **Step 3: Implement the minimal status model and progress handling**

Add:

```swift
enum IPhoneReceiveStatusKind: Sendable, Equatable {
    case waiting
    case active
    case saved
    case failed
}

struct IPhoneReceiveStatus: Sendable, Equatable {
    let kind: IPhoneReceiveStatusKind
    let title: String
    let message: String
    let fileName: String?
    let occurredAt: Date?
    let percent: Int?
}
```

Inject these operations, with inert defaults for existing tests:

```swift
typealias LoadOutcome = @Sendable (UUID) -> IPhoneReceiveOutcome?
typealias SaveOutcome = @Sendable (IPhoneReceiveOutcome) throws -> Void
typealias ClearOutcome = @Sendable (UUID) throws -> Void
```

On `refresh`, load only the current receiver's outcome. On `.completed` or
`.failed`, create an in-memory outcome immediately and attempt an atomic save;
failure to save the status record must not fail or undo the actual file
operation. `.idle` does not clear the outcome. Active transfer stages take
priority in `receiveStatus`; otherwise use the latest outcome, then registered
waiting, then registration required. Clear the matching outcome before a
successful registration reset.

- [ ] **Step 4: Run tests and verify GREEN**

Run `./scripts/test-ios.sh`. Expected: new status tests and all existing progress, fallback, USB export, and error separation tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/UI/USBReceiverViewModel.swift Tests/USBReceiverViewModelTests.swift
git commit -m "feat: expose durable PC receive status"
```

---

### Task 4: Present the same status on main and receiver screens

**Files:**
- Modify: `App/UI/ContentView.swift`
- Modify: `App/UI/USBReceiverView.swift`
- Modify: `App/Testing/ForegroundReceiveSimulation.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`
- Modify: `Tests/ProjectSmokeTests.swift`

**Interfaces:**
- Consumes: `USBReceiverViewModel.receiveStatus` from Task 3.
- Produces: gray/blue/green/red SwiftUI status panels and stable accessibility identifiers `pc-receive-status`, `pc-receive-success`, and `pc-receive-error`.

- [ ] **Step 1: Write failing UI contracts and simulations**

Add unit/source contracts requiring both views to render a shared status helper
from `receiveStatus`. Extend the simulator fixture with launch arguments for a
saved result and a categorized server failure. Add UI tests that assert:

```swift
XCTAssertTrue(app.otherElements["pc-receive-success"].waitForExistence(timeout: 10))
XCTAssertTrue(app.staticTexts["iPhone 저장 완료"].exists)
XCTAssertTrue(app.otherElements["pc-receive-error"].waitForExistence(timeout: 10))
XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "서버 오류")).firstMatch.exists)
```

Retain screenshots `main-receive-success` and `main-receive-error`.

- [ ] **Step 2: Run tests and verify RED**

Run `./scripts/test-ios.sh`. Expected: the identifiers and status fixture modes are missing.

- [ ] **Step 3: Implement compact status panels**

Render these mappings without adding a second independent state source:

```swift
waiting -> gray, clock, registration/waiting text
active  -> cyan, arrow.down.circle.fill, current title/file/percent
saved   -> green, checkmark.circle.fill, destination/file/count/time
failed  -> red, exclamationmark.triangle.fill, categorized reason/time
```

The main receiver card remains a navigation link and shows the compact status.
The detailed progress card shows the same title/message and retains the existing
progress bar, byte count, speed, ETA, expiry, stored-file controls, and USB
controls. Continue to show `incomingModel.lastError` as a separate discovery
warning so it cannot overwrite a verified saved result. Add a clear `상세 확인`
cue for failures by retaining the navigation chevron rather than introducing an
automatic retry.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

Run `./scripts/test-ios.sh`. Expected: all unit/integration/UI tests pass and all three screenshots show full-height content with explicit receive state.

- [ ] **Step 5: Commit**

```bash
git add App/UI/ContentView.swift App/UI/USBReceiverView.swift App/Testing/ForegroundReceiveSimulation.swift UITests/ForegroundReceiveUITests.swift Tests/ProjectSmokeTests.swift
git commit -m "feat: clarify PC receive status in iPhone UI"
```

---

### Task 5: Build, inspect, and publish the SideStore update

**Files:**
- Modify: `project.yml`
- Modify: `Tests/ProjectSmokeTests.swift`
- Modify: `docs/install.md`
- Create: `docs/verification/2026-08-30-fullscreen-receive-feedback.md`
- Generated: `dist/SimpleCameraAutoSender.ipa`

**Interfaces:**
- Consumes: the verified application from Tasks 1-4.
- Produces: the `0.3.5 (16)` IPA and a SideStore QR pointing at the public release asset.

- [ ] **Step 1: Write the failing release contract**

Bump from `0.3.4 (15)` to `0.3.5 (16)` and update the version contract test to
require `MARKETING_VERSION: 0.3.5` and `CURRENT_PROJECT_VERSION: 16`. Run the
contract before editing `project.yml`; expected: FAIL on the old version.

- [ ] **Step 2: Apply the version and installation documentation update**

Set `MARKETING_VERSION: 0.3.5` and `CURRENT_PROJECT_VERSION: 16` in
`project.yml`. Document the full-screen fix and durable latest receive result in
`docs/install.md`; do not claim closed-app push or physical USB verification.

- [ ] **Step 3: Run full CI and build the unsigned IPA**

Run on macOS:

```bash
./scripts/test-ios.sh
./scripts/build-unsigned-ipa.sh
```

Expected: all XCTest/XCUITest cases pass, the IPA builds, `unzip -t` passes, and
`scripts/verify-ipa.py` passes.

- [ ] **Step 4: Inspect the final artifact**

Verify the IPA's `Info.plist` contains the exact bundle identifier, version,
build, iPhone platform/minimum iOS values, `UIFileSharingEnabled`,
`LSSupportsOpeningDocumentsInPlace`, and `UILaunchScreen`. Record the IPA size
and SHA-256. Confirm production code contains no `--ui-test-*` fixture strings.

- [ ] **Step 5: Publish and independently verify the SideStore QR**

Publish the CI-built IPA and install QR to a new GitHub release. Download the
public asset anonymously, compare its SHA-256 with the CI artifact, decode the
QR independently, and require this payload shape:

```text
sidestore://install?url=https%3A%2F%2Fgithub.com%2Fhejong2-byte%2Fsimplecamera-auto-sender-ios%2Freleases%2Flatest%2Fdownload%2FSimpleCameraAutoSender.ipa
```

- [ ] **Step 6: Commit verification evidence**

```bash
git add project.yml Tests/ProjectSmokeTests.swift docs/install.md docs/verification/2026-08-30-fullscreen-receive-feedback.md
git commit -m "release: verify full-screen receive feedback update"
```

Record test counts, workflow URL, artifact hashes, QR decode result, simulator
limits, and the remaining physical iPhone 14 Pro check. Never report device USB
or full-screen verification as complete until the user installs and observes it.
