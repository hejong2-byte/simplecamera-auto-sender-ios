# USB Storage File Explorer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app SD/USB file explorer that sends one or more selected files to an existing named PC receiver.

**Architecture:** A focused `USBStorageFileExplorer` validates security-scoped paths and lists only navigable directories and transferable regular files. `USBReceiverViewModel` owns the browsing and selection state because it already owns the persisted SD/USB bookmark. `USBStorageManagementView` passes selected URLs to the existing `ContentViewModel.sendSelectedFiles` path and uses `TextTransferViewModel` as the single saved-recipient source.

**Tech Stack:** Swift 5, SwiftUI, Foundation security-scoped URLs, XCTest, XcodeGen, GitHub Actions macOS iOS Simulator, existing `ManualMediaTransferService` and `ManualBackgroundTransferEngine`.

## Global Constraints

- The SD/USB source is read-only for this feature; never create, rename, move, or delete a source item.
- Directories are navigation-only and cannot be selected for transfer.
- Regular files support single and multiple selection.
- The current `TextSavedRecipientStore` data and six-digit PC mailbox mapping remain the only destination source.
- The existing background manual file-transfer protocol remains unchanged.
- `.SimpleCameraReceiver` is an app-owned staging directory and is not shown or selectable.
- The selected storage root's security scope remains active until file preparation returns.
- Keep unrelated `.wrangler/` and release verification directories unchanged.
- The feature release is `0.3.38`, build `49`.

---

### Task 1: Security-scoped storage browser

**Files:**
- Create: `App/Receive/USBStorageFileExplorer.swift`
- Create: `Tests/USBStorageFileExplorerTests.swift`
- Modify: `.github/workflows/usb-regression.yml`

**Interfaces:**
- Consumes: `USBBookmarkDestination` from `App/Receive/USBBookmarkStore.swift`.
- Produces: `USBStorageFileEntry`, `USBStorageFileExplorer.list(destination:relativePath:)`, and `USBStorageFileExplorer.withFiles(destination:relativePaths:operation:)`.

- [ ] **Step 1: Write failing service tests**

Add tests that create a real temporary directory tree and require directory-first sorting, hidden-file visibility, `.SimpleCameraReceiver` exclusion, path traversal rejection, symbolic-link rejection, and security-scope lifetime across an asynchronous send closure.

```swift
func testListsDirectoriesBeforeFilesAndIncludesHiddenRegularFiles() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("MAP"), withIntermediateDirectories: true)
    try Data("a".utf8).write(to: root.appendingPathComponent("z.txt"))
    try Data("b".utf8).write(to: root.appendingPathComponent(".hidden"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".SimpleCameraReceiver"), withIntermediateDirectories: true)

    let explorer = USBStorageFileExplorer(startAccessing: { _ in true }, stopAccessing: { _ in })
    let entries = try explorer.list(destination: destination(root), relativePath: "")

    XCTAssertEqual(entries.map(\.name), ["MAP", ".hidden", "z.txt"])
    XCTAssertEqual(entries.map(\.kind), [.directory, .file, .file])
}

func testKeepsRootScopeOpenUntilSelectedFilesFinishPreparing() async throws {
    let root = temporaryDirectory()
    try Data("payload".utf8).write(to: root.appendingPathComponent("file.bin"))
    let scope = ScopeLog()
    let explorer = USBStorageFileExplorer(
        startAccessing: { scope.start($0) },
        stopAccessing: { scope.stop($0) }
    )

    try await explorer.withFiles(
        destination: destination(root),
        relativePaths: ["file.bin"]
    ) { urls in
        XCTAssertTrue(scope.isActive)
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data("payload".utf8))
    }
    XCTAssertFalse(scope.isActive)
}
```

- [ ] **Step 2: Run the tests to prove RED**

Push the test-only commit to `codex/foreground-receive-alert` and run the CI workflow.

```powershell
git add Tests/USBStorageFileExplorerTests.swift .github/workflows/usb-regression.yml
git commit -m "test: require USB storage file explorer"
git push origin codex/foreground-receive-alert
gh run watch --exit-status
```

Expected: compilation fails because `USBStorageFileExplorer` and `USBStorageFileEntry` do not exist.

- [ ] **Step 3: Implement the minimal explorer**

Create the focused types below. `validatedURL` must reject absolute paths, `..`, symlinks, non-regular files, and any standardized URL outside the selected root.

```swift
enum USBStorageFileEntryKind: Sendable, Equatable { case directory, file }

struct USBStorageFileEntry: Identifiable, Sendable, Equatable {
    let relativePath: String
    let name: String
    let kind: USBStorageFileEntryKind
    let size: Int64
    let modifiedAt: Date?
    var id: String { relativePath }
}

enum USBStorageFileExplorerError: LocalizedError, Equatable {
    case destinationMissing
    case permissionExpired
    case unavailable
    case invalidPath
    case invalidFile
}

struct USBStorageFileExplorer: @unchecked Sendable {
    func list(
        destination: USBBookmarkDestination,
        relativePath: String
    ) throws -> [USBStorageFileEntry]

    func withFiles<T: Sendable>(
        destination: USBBookmarkDestination,
        relativePaths: [String],
        operation: @Sendable ([URL]) async throws -> T
    ) async throws -> T
}
```

- [ ] **Step 4: Run focused tests and prove GREEN**

```bash
xcodegen generate
xcodebuild test -project SimpleCameraAutoSender.xcodeproj -scheme SimpleCameraAutoSender \
  -destination "platform=iOS Simulator,id=${DEVICE_ID}" -parallel-testing-enabled NO \
  -only-testing:SimpleCameraAutoSenderTests/USBStorageFileExplorerTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `USBStorageFileExplorerTests` passes with no unexpected process restart.

- [ ] **Step 5: Commit the service**

```bash
git add App/Receive/USBStorageFileExplorer.swift Tests/USBStorageFileExplorerTests.swift .github/workflows/usb-regression.yml
git commit -m "feat: browse files on selected USB storage"
```

---

### Task 2: Browsing, selection, and transfer handoff state

**Files:**
- Modify: `App/UI/USBReceiverViewModel.swift`
- Create: `Tests/USBStorageFileSelectionTests.swift`
- Modify: `.github/workflows/usb-regression.yml`

**Interfaces:**
- Consumes: Task 1's `USBStorageFileExplorer`, the existing private `USBBookmarkStore`, and a UI-supplied async send closure.
- Produces: published explorer state and `refreshStorageFiles`, `openStorageDirectory`, `openParentStorageDirectory`, `toggleStorageFileSelection`, `clearStorageFileSelection`, and `sendSelectedStorageFiles`.

- [ ] **Step 1: Write failing view-model tests**

Require navigation, multi-selection, selected-byte totals, stale-selection removal after refresh, and a transfer callback that receives the selected URLs and code while the root scope is active.

```swift
func testSelectsMultipleStorageFilesAndSendsThemToSavedCode() async throws {
    let fixture = try makeStorageFixture(files: ["one.txt": 3, "two.bin": 5])
    let model = fixture.model
    await model.refreshStorageFiles()
    model.toggleStorageFileSelection("one.txt")
    model.toggleStorageFileSelection("two.bin")

    XCTAssertEqual(model.selectedStorageFileCount, 2)
    XCTAssertEqual(model.selectedStorageFileBytes, 8)

    let capture = FileSendCapture()
    await model.sendSelectedStorageFiles(recipientCode: "709592") { urls, code in
        await capture.record(urls: urls, code: code)
    }
    XCTAssertEqual(await capture.code, "709592")
    XCTAssertEqual(Set(await capture.names), ["one.txt", "two.bin"])
}
```

- [ ] **Step 2: Run the new tests to prove RED**

Run the USB regression workflow after committing only the new tests. Expected: compilation fails because the explorer state and actions do not exist on `USBReceiverViewModel`.

- [ ] **Step 3: Add minimal state and actions**

Add these published values and computed values to `USBReceiverViewModel`:

```swift
@Published private(set) var storageEntries: [USBStorageFileEntry] = []
@Published private(set) var storageRelativePath = ""
@Published private(set) var selectedStorageFilePaths: Set<String> = []
@Published private(set) var isLoadingStorageFiles = false
@Published private(set) var isSendingStorageFiles = false
@Published private(set) var storageExplorerError: String?

var selectedStorageFileCount: Int { selectedStorageFilePaths.count }
var selectedStorageFileBytes: Int64 {
    storageEntries.filter { selectedStorageFilePaths.contains($0.relativePath) }
        .reduce(0) { $0 + $1.size }
}
```

Use the existing bookmark to resolve the destination for every refresh and send. Clear the list and selection when the destination is cleared or unavailable. `sendSelectedStorageFiles` must keep selection on preparation failure and clear it only after the existing send callback returns.

- [ ] **Step 4: Run selection and existing receiver tests**

```bash
xcodebuild test -project SimpleCameraAutoSender.xcodeproj -scheme SimpleCameraAutoSender \
  -destination "platform=iOS Simulator,id=${DEVICE_ID}" -parallel-testing-enabled NO \
  -only-testing:SimpleCameraAutoSenderTests/USBStorageFileSelectionTests \
  -only-testing:SimpleCameraAutoSenderTests/USBReceiverViewModelTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both suites pass; existing receive, copy, deletion, and destination selection behavior remains unchanged.

- [ ] **Step 5: Commit the state integration**

```bash
git add App/UI/USBReceiverViewModel.swift Tests/USBStorageFileSelectionTests.swift .github/workflows/usb-regression.yml
git commit -m "feat: select USB files for PC transfer"
```

---

### Task 3: Storage management UI and saved-PC destination picker

**Files:**
- Modify: `App/UI/ContentView.swift`
- Modify: `App/UI/SettingsView.swift`
- Modify: `App/UI/USBStorageManagementView.swift`
- Modify: `Tests/ForegroundReceiveContractTests.swift`
- Modify: `Tests/ProjectSmokeTests.swift`
- Modify: `App/Testing/ForegroundReceiveSimulation.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`

**Interfaces:**
- Consumes: Task 2 explorer state/actions, `ContentViewModel.sendSelectedFiles(_:recipientCode:)`, and `TextTransferViewModel.savedRecipients`.
- Produces: the visible storage file explorer, multiple-selection controls, saved-PC sheet, and live preparation/upload status.

- [ ] **Step 1: Write failing UI contract and simulator tests**

Require source-level integration and an iOS simulator flow that opens Settings, enters storage management, selects two fixture files, chooses saved `행정망 PC · 709592`, and observes the transfer handoff status.

```swift
func testStorageManagementExposesMultiFilePCTransfer() throws {
    let storage = try source("App/UI/USBStorageManagementView.swift")
    XCTAssertTrue(storage.contains("파일 탐색기"))
    XCTAssertTrue(storage.contains("선택 파일 PC로 전송"))
    XCTAssertTrue(storage.contains("저장된 PC 수신코드"))
    XCTAssertTrue(storage.contains("toggleStorageFileSelection"))
    XCTAssertTrue(storage.contains("sendSelectedStorageFiles"))
}
```

- [ ] **Step 2: Run the UI contract to prove RED**

Expected: assertions fail because the explorer card and destination sheet are not present.

- [ ] **Step 3: Wire existing models into Settings**

Change the Settings destination in `ContentView` to:

```swift
SettingsView(
    model: model,
    receiverModel: receiverModel,
    filePickerModel: filePickerModel,
    textModel: textModel
)
```

Add `@ObservedObject var textModel: TextTransferViewModel` to `SettingsView` and pass all three operational models to `USBStorageManagementView`.

- [ ] **Step 4: Build the explorer card and recipient sheet**

Place `fileExplorerCard` between `destinationCard` and `deletionCard`. Use `LazyVStack`, folder buttons with chevrons, file selection circles, file size/date labels, and these primary controls:

```swift
Button("선택 해제") { model.clearStorageFileSelection() }
Button("선택 파일 PC로 전송") {
    Task {
        await textModel.refreshRecipients()
        if textModel.savedRecipients.isEmpty {
            recipientError = "저장된 PC 수신코드가 없습니다. 파일 전송에서 PC를 먼저 저장해 주세요."
        } else {
            isChoosingStorageRecipient = true
        }
    }
}
```

The recipient sheet lists `recipient.name` and `recipient.code`. Selecting one calls:

```swift
await model.sendSelectedStorageFiles(recipientCode: recipient.code) { urls, code in
    await transferModel.sendSelectedFiles(urls, recipientCode: code)
}
```

Show `transferModel.manualTransferMessage` and `manualProgress.percent` inside the card while preparation or upload is active.

- [ ] **Step 5: Run UI and full unit tests**

```bash
./scripts/test-ios.sh
```

Expected: all unit and UI tests pass; the iPhone-size screenshot has no clipped row labels or inaccessible transfer button.

- [ ] **Step 6: Commit the UI**

```bash
git add App/UI/ContentView.swift App/UI/SettingsView.swift App/UI/USBStorageManagementView.swift \
  App/Testing/ForegroundReceiveSimulation.swift Tests/ForegroundReceiveContractTests.swift \
  Tests/ProjectSmokeTests.swift UITests/ForegroundReceiveUITests.swift
git commit -m "feat: send selected USB files to saved PCs"
```

---

### Task 4: Release alignment and delivery

**Files:**
- Modify: `project.yml`
- Modify: `README.md`
- Modify: `docs/install.md`
- Modify: `docs/install-qr.png` through the existing release workflow

**Interfaces:**
- Consumes: Tasks 1-3 and the existing SideStore release workflow.
- Produces: version `0.3.38` build `49`, verified IPA, GitHub release, and install QR.

- [ ] **Step 1: Write failing release assertions**

Update `ProjectSmokeTests` to require `MARKETING_VERSION: 0.3.38`, `CURRENT_PROJECT_VERSION: 49`, and documentation mentioning SD/USB explorer multi-file PC transfer.

- [ ] **Step 2: Run release assertions to prove RED**

Expected: current `0.3.37`/`48` assertions fail.

- [ ] **Step 3: Align version and documentation**

Set:

```yaml
CURRENT_PROJECT_VERSION: 49
MARKETING_VERSION: 0.3.38
```

Document the exact path `설정 → SD/USB 저장장치 관리 → 파일 탐색기`, multi-selection, saved PC selection, source preservation, and the need to keep the device connected until file preparation completes.

- [ ] **Step 4: Commit release metadata**

```bash
git add project.yml README.md docs/install.md Tests/ProjectSmokeTests.swift
git commit -m "chore: prepare v0.3.38 release"
```

- [ ] **Step 5: Run all required regressions**

Push the branch and wait for `CI`, `USB copy and cleanup regression`, `Production SHA memory regression`, and `Receive selection regression - iOS 26`.

```powershell
git push origin codex/foreground-receive-alert
gh run list --branch codex/foreground-receive-alert --limit 10
```

Expected: all required runs conclude `success`, with no simulator process restart marker.

- [ ] **Step 6: Build and verify the SideStore release**

```bash
git tag v0.3.38
git push origin v0.3.38
```

Wait for `Release SideStore IPA`, download the assets, run `unzip -t`, `scripts/verify-ipa.py`, validate the SideStore QR URI, and compare SHA-256 values against the release assets.
