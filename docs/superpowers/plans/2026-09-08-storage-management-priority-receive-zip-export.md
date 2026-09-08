# Storage Management, Priority Receive and ZIP Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone SD/USB management menu, allow exact pending PC files to be selected for priority reception, and let stored iPhone ZIP files be copied to SD/USB either extracted or intact.

**Architecture:** Keep the existing relay protocol and approve only exact delivery IDs selected in a new foreground sheet. Reuse the existing bookmark and safe deletion services in a focused storage-management view, and parameterize the existing verified USB exporter with an archive mode so its current safe ZIP pipeline remains the only extraction path.

**Tech Stack:** Swift 5, SwiftUI, XCTest, CryptoKit, ZIPFoundation 0.9.20, XcodeGen, GitHub Actions macOS/iOS Simulator.

## Global Constraints

- Two or more pending deliveries start with no selection and do not lease or approve any file until **선택 파일 먼저 받기** is confirmed.
- Unselected deliveries remain on the server and visible in the pending list.
- A single pending delivery retains the existing direct archive/destination prompt.
- Selected deliveries are processed one at a time in stable oldest-first order.
- Stored ZIP export asks **압축 해제해서 복사** or **ZIP 그대로 복사**; non-ZIP files are always copied unchanged.
- ZIP extraction uses app-private temporary storage and the existing `SafeZIPExtractor`; only temporary and attempt-partial data is removed automatically.
- iPhone source files are never deleted automatically.
- SD/USB deletion is limited to the selected folder's contents, preserves the selected folder, and requires inspection plus a second confirmation.
- No formatting, filesystem conversion, relay API change or Windows sender change is included.
- Release version is `0.3.17` and build number is `28`.

---

### Task 1: Model exact pending-file selection

**Files:**
- Modify: `App/UI/IPhoneIncomingFilesViewModel.swift`
- Modify: `Tests/IPhoneIncomingFilesViewModelTests.swift`

**Interfaces:**
- Produces: `selectionBatch: IPhoneIncomingBatch?`, `selectedPendingFileIDs: Set<UUID>`, `needsPendingSelection`, `togglePendingFileSelection(_:)`, `selectAllPendingFiles()`, `clearPendingFileSelection()`, `cancelPendingFileSelection()`, and `confirmPendingFileSelection()`.
- Preserves: `prompt` as the archive/destination state for the frozen selected subset.

- [ ] **Step 1: Write failing selection tests**

```swift
func testTwoArrivalsRequireSelectionAndApproveOnlyChosenFile() async throws {
    let context = try makeContext(count: 2)
    await activate(context)
    XCTAssertNil(context.model.prompt)
    XCTAssertEqual(context.model.selectionBatch?.files.count, 2)
    XCTAssertTrue(context.model.selectedPendingFileIDs.isEmpty)

    let chosen = try XCTUnwrap(context.model.selectionBatch?.files.last)
    context.model.togglePendingFileSelection(chosen.deliveryID)
    XCTAssertTrue(context.model.confirmPendingFileSelection())
    let prompt = try XCTUnwrap(context.model.prompt)
    XCTAssertEqual(prompt.files.map(\.deliveryID), [chosen.deliveryID])
    XCTAssertTrue(context.model.accept(prompt, destination: .iphoneLocal))
    XCTAssertEqual(
        Set(try context.store.destinations(receiverID: prompt.receiverID).keys),
        [chosen.deliveryID]
    )
    XCTAssertEqual(context.model.pendingFiles.count, 1)
}

func testNewArrivalDoesNotJoinFrozenSelectionAndDisappearedSelectionIsRemoved() async throws {
    let context = try makeContext(count: 2)
    await activate(context)
    let chosen = try XCTUnwrap(context.model.selectionBatch?.files.first)
    context.model.togglePendingFileSelection(chosen.deliveryID)
    context.server.append(file(index: 3))
    await context.model.refresh()
    XCTAssertEqual(context.model.selectionBatch?.files.count, 2)
    context.server.replace(context.server.files.filter { $0.deliveryID != chosen.deliveryID })
    await context.model.refresh()
    XCTAssertFalse(context.model.selectedPendingFileIDs.contains(chosen.deliveryID))
    XCTAssertFalse(context.model.confirmPendingFileSelection())
}
```

Retain and update the existing one-file, postponed-batch, mixed ZIP and receiver-change tests so they assert that a single file still creates `prompt`, while multiple files create `selectionBatch`.

- [ ] **Step 2: Run CI and verify RED**

Run:

```text
git push origin HEAD:codex/foreground-receive-alert
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

Expected: compilation fails because the pending-selection properties and methods do not exist.

- [ ] **Step 3: Implement the selection state machine**

Add published state and keep it receiver-scoped:

```swift
@Published private(set) var selectionBatch: IPhoneIncomingBatch?
@Published private(set) var selectedPendingFileIDs: Set<UUID> = []

var needsPendingSelection: Bool { selectionBatch != nil }
var pendingSelectionBytes: Int64 {
    selectionBatch?.files
        .filter { selectedPendingFileIDs.contains($0.deliveryID) }
        .reduce(0) { $0 + max(0, $1.size) } ?? 0
}
```

Split presentation into `present(_:)`: one file creates the existing staged prompt; two or more files create `selectionBatch` with no selected IDs. `confirmPendingFileSelection()` intersects the selected IDs with the still-frozen batch, clears the sheet state, and creates a prompt from only those files. Refresh filters disappeared IDs from both the frozen batch and selection but never adds newly arrived files. Receiver changes, deactivation and cancellation clear transient selection state. `showPendingFiles()` uses the same one-versus-many routing.

- [ ] **Step 4: Run focused tests and verify GREEN**

Expected: every `IPhoneIncomingFilesViewModelTests` case passes, with exact selected approval and no implicit approval of the remainder.

- [ ] **Step 5: Commit**

```text
git add App/UI/IPhoneIncomingFilesViewModel.swift Tests/IPhoneIncomingFilesViewModelTests.swift
git commit -m "feat: select pending files for priority reception"
```

### Task 2: Present the pending-file selection sheet

**Files:**
- Create: `App/UI/PendingIncomingSelectionView.swift`
- Modify: `App/UI/ContentView.swift`
- Modify: `App/UI/USBReceiverView.swift`
- Modify: `App/Testing/ForegroundReceiveSimulation.swift`
- Modify: `Tests/ForegroundReceiveContractTests.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`

**Interfaces:**
- Consumes: Task 1 selection state and methods.
- Produces: a modal checklist with accessibility identifiers `pending-file-selection`, `pending-file-<deliveryID>`, `pending-select-all`, `pending-clear-selection`, and `pending-confirm-selection`.

- [ ] **Step 1: Write failing source-contract and UI tests**

```swift
func testMultiplePendingFilesUseASelectionSheet() throws {
    let root = try source("App/UI/ContentView.swift")
    let selection = try source("App/UI/PendingIncomingSelectionView.swift")
    XCTAssertTrue(root.contains("PendingIncomingSelectionView"))
    XCTAssertTrue(selection.contains("선택 파일 먼저 받기"))
    XCTAssertTrue(selection.contains("전체 선택"))
    XCTAssertTrue(selection.contains("선택 해제"))
    XCTAssertTrue(selection.contains("보관 만료"))
}
```

Extend the receive simulation to create two files when launched with `--ui-test-multiple-incoming`. The UI test opens the app, verifies both names, selects only the second file, taps **선택 파일 먼저 받기**, and verifies the existing destination prompt names only that file.

- [ ] **Step 2: Run CI and verify RED**

Expected: source-contract compilation or assertions fail because `PendingIncomingSelectionView` and the multi-file simulation do not exist.

- [ ] **Step 3: Implement the sheet and connect it to both pending buttons**

Create a SwiftUI `List` whose rows display filename, formatted size, arrival and expiration time. Row taps call `togglePendingFileSelection`. The footer displays selected count and combined size. Disable the primary action while `selectedPendingFileIDs` is empty. Dismissal calls `cancelPendingFileSelection()` and records no error.

Attach one `.sheet(isPresented:)` at `ContentView` so both the home and receiver pending buttons call `showPendingFiles()` and share the same presentation. Include the new sheet in `canPresentIncomingFiles` conflict checks so it cannot overlap folder import, deletion, ZIP export choice or an active receive dialog.

- [ ] **Step 4: Run contract and UI tests and verify GREEN**

Expected: the sheet renders exact metadata, selected-only continuation works, and one-file arrival tests remain unchanged.

- [ ] **Step 5: Commit**

```text
git add App/UI/PendingIncomingSelectionView.swift App/UI/ContentView.swift App/UI/USBReceiverView.swift App/Testing/ForegroundReceiveSimulation.swift Tests/ForegroundReceiveContractTests.swift UITests/ForegroundReceiveUITests.swift
git commit -m "feat: add pending receive selection sheet"
```

### Task 3: Choose how stored ZIP files are exported

**Files:**
- Modify: `App/Receive/IPhoneUSBExportService.swift`
- Modify: `App/Application/USBReceiverDependencies.swift`
- Modify: `App/UI/USBReceiverViewModel.swift`
- Modify: `App/UI/USBReceiverView.swift`
- Modify: `Tests/IPhoneUSBExportServiceTests.swift`
- Modify: `Tests/USBReceiverViewModelTests.swift`
- Modify: `Tests/ForegroundReceiveContractTests.swift`

**Interfaces:**
- Changes: `IPhoneUSBExportService.export(_:to:archiveMode:)` and `USBReceiverViewModel.ExportFiles` receive `IPhoneReceiveArchiveMode`.
- Produces: `storedZIPExportFilesPendingChoice`, `needsStoredZIPExportChoice`, `requestStoredFilesUSBExport()`, `confirmStoredZIPExport(_:)`, and `cancelStoredZIPExportChoice()`.

- [ ] **Step 1: Write failing exporter and view-model tests**

```swift
func testZIPCanBeCopiedIntactWithoutExtraction() async throws {
    let context = try makeContext()
    let zip = try makeZIPStoredFile(in: context.sourceDirectory)
    let summary = await context.service.export(
        [zip], to: context.destination, archiveMode: .keepArchive
    )
    XCTAssertEqual(summary.failed, [])
    let name = try XCTUnwrap(summary.verified.first?.usbStoredName)
    XCTAssertEqual(URL(fileURLWithPath: name).pathExtension.lowercased(), "zip")
    XCTAssertEqual(
        try Data(contentsOf: context.usbDirectory.appendingPathComponent(name)),
        try Data(contentsOf: zip.url)
    )
}

func testSelectedZIPWaitsForExportChoice() async throws {
    let context = try makeViewModelContext(storedNames: ["archive.zip", "note.txt"])
    context.model.toggleStoredFileSelection(context.files[0].id)
    await context.model.requestStoredFilesUSBExport()
    XCTAssertTrue(context.model.needsStoredZIPExportChoice)
    XCTAssertEqual(context.exportCalls.count, 0)
}
```

Also add extract-mode regression, mixed ZIP/non-ZIP mode, cancel-with-selection-preserved, and failed-extraction-original-preserved assertions.

- [ ] **Step 2: Run CI and verify RED**

Expected: compilation fails because `export(_:to:archiveMode:)` and the ZIP-choice view-model APIs do not exist.

- [ ] **Step 3: Parameterize the exporter without duplicating copy logic**

Change the public method to:

```swift
func export(
    _ files: [IPhoneStoredFile],
    to destination: USBBookmarkDestination,
    archiveMode: IPhoneReceiveArchiveMode
) -> IPhoneUSBExportSummary
```

Pass `archiveMode` into `exportOne`. Call `exportZIP` only when the source extension is ZIP and the mode is `.extract`; otherwise use the existing ordinary verified file-copy path. Non-ZIP behavior is identical for both modes. Preserve the existing extraction `defer` cleanup and deletion-decision store.

- [ ] **Step 4: Add the batch-level choice to the view model and UI**

`requestStoredFilesUSBExport()` snapshots the selected files. If no ZIP is present it exports immediately with `.keepArchive`; otherwise it sets `storedZIPExportFilesPendingChoice` and performs no copy. The confirmation methods consume that immutable snapshot with `.extract` or `.keepArchive`; cancel clears only the pending choice and preserves the user's checkmarks.

Add a confirmation dialog to `USBReceiverView` with **압축 해제해서 복사**, **ZIP 그대로 복사**, and **취소**. Disable stored-file selection and conflicting receive/deletion operations while the dialog is active.

- [ ] **Step 5: Run focused tests and verify GREEN**

Expected: both ZIP modes, mixed selections, cancellation, cleanup and existing non-ZIP export tests pass.

- [ ] **Step 6: Commit**

```text
git add App/Receive/IPhoneUSBExportService.swift App/Application/USBReceiverDependencies.swift App/UI/USBReceiverViewModel.swift App/UI/USBReceiverView.swift Tests/IPhoneUSBExportServiceTests.swift Tests/USBReceiverViewModelTests.swift Tests/ForegroundReceiveContractTests.swift
git commit -m "feat: choose stored ZIP USB export mode"
```

### Task 4: Move SD/USB cleanup into a dedicated Settings menu

**Files:**
- Create: `App/UI/USBStorageManagementView.swift`
- Modify: `App/UI/SettingsView.swift`
- Modify: `Tests/ProjectSmokeTests.swift`
- Modify: `Tests/ForegroundReceiveContractTests.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`

**Interfaces:**
- Consumes: existing `USBReceiverViewModel` destination, inspection and deletion APIs.
- Produces: Settings navigation row `SD/USB 저장장치 관리` and a dedicated screen owning its folder importer and delete confirmation.

- [ ] **Step 1: Write failing menu contract and UI tests**

```swift
func testSettingsUsesDedicatedStorageManagementScreen() throws {
    let settings = try source("App/UI/SettingsView.swift")
    let storage = try source("App/UI/USBStorageManagementView.swift")
    XCTAssertTrue(settings.contains("SD/USB 저장장치 관리"))
    XCTAssertTrue(storage.contains("선택한 저장장치 내용 전체 삭제"))
    XCTAssertTrue(storage.contains("파일시스템(참고)"))
    XCTAssertFalse(settings.contains("Button(\"SD/USB 전체 파일 삭제\""))
}
```

The UI test opens Settings, enters the storage-management row, verifies folder status and filesystem information, starts inspection, verifies the file/folder/size confirmation, cancels once, then confirms against simulation-only temporary content and verifies the completion state.

- [ ] **Step 2: Run CI and verify RED**

Expected: assertions fail because the dedicated view and navigation row do not exist.

- [ ] **Step 3: Implement the dedicated screen by reusing the existing deletion engine**

Create `USBStorageManagementView` with destination name, filesystem description, folder choose/reselect, clear selection, destructive delete action, progress, completion and error labels. Host `.fileImporter` and the existing two-step `.confirmationDialog` only in this view. Call `cancelUSBFolderDeletion()` on disappearance.

In `SettingsView`, remove its file importer, delete confirmation and inline destructive controls. Add a `NavigationLink` card showing the destination summary and chevron. Keep receiver registration and cellular settings in `receiverSettingsCard`; do not duplicate deletion logic or create another service.

- [ ] **Step 4: Run contract and UI tests and verify GREEN**

Expected: navigation and deletion simulation pass, while all existing cleanup service and view-model safety tests remain green.

- [ ] **Step 5: Commit**

```text
git add App/UI/USBStorageManagementView.swift App/UI/SettingsView.swift Tests/ProjectSmokeTests.swift Tests/ForegroundReceiveContractTests.swift UITests/ForegroundReceiveUITests.swift
git commit -m "feat: add standalone SD USB management menu"
```

### Task 5: Documentation, version and full verification

**Files:**
- Modify: `README.md`
- Modify: `docs/install.md`
- Modify: `project.yml`
- Modify: `Tests/ProjectSmokeTests.swift`

**Interfaces:**
- Produces: app version `0.3.17` build `28` with documentation matching all three workflows.

- [ ] **Step 1: Add failing release-contract assertions**

Assert `MARKETING_VERSION: 0.3.17`, `CURRENT_PROJECT_VERSION: 28`, the pending-selection labels, both stored-ZIP export choices, and the dedicated storage-management menu.

- [ ] **Step 2: Run CI and verify RED**

Expected: version/documentation assertions fail while the project remains `0.3.16` (27).

- [ ] **Step 3: Update the version and user instructions**

Document exact pending-file selection, single-file behavior, unselected server retention, both stored-ZIP export modes, temporary cleanup/original preservation, and the Settings storage-management path. Change only the final marketing-version component and increment the build number once.

- [ ] **Step 4: Run full CI and verify GREEN**

Push the completed branch and require the latest `CI` workflow to finish successfully. Read the full job output and confirm zero failed XCTest cases, successful UI tests, successful unsigned IPA build, and artifact upload. Download the exact CI artifact and run:

```text
python scripts/verify-ipa.py <downloaded-ipa>
```

Verify bundle version `0.3.17`, build `28`, IPA ZIP CRC and absence of unexpected files. Do not publish a release or tag until the user asks for an installation build/QR.

- [ ] **Step 5: Commit**

```text
git add README.md docs/install.md project.yml Tests/ProjectSmokeTests.swift
git commit -m "chore: prepare 0.3.17 feature build"
```
