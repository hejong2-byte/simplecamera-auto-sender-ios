# Repeat Receive and ZIP Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-offer every unacknowledged PC delivery whenever the iPhone app becomes active and ask how to handle ZIP files before choosing a final destination.

**Architecture:** Persist a receive decision containing destination and archive mode, while treating that decision only as authorization rather than completion. Extend the foreground prompt into a two-stage state machine and extend direct USB reception so selected ZIP files download to private iPhone staging, extract safely, copy through a hidden USB partial folder, verify, ACK, and then remove only temporary files.

**Tech Stack:** Swift 5, SwiftUI, XCTest, CryptoKit, ZIPFoundation 0.9.20, URLSession-backed receiver client, GitHub Actions macOS/iOS Simulator.

## Global Constraints

- A dismissed prompt or app exit is postponement and must not create a receive error.
- Every available or leased, unacknowledged server delivery is offered again on the next inactive-to-active transition.
- ZIP handling is asked before destination selection.
- `압축 해제` uses private iPhone staging and USB/SD as the final destination.
- `ZIP 그대로 저장` supports either iPhone or USB/SD.
- A server ACK occurs only after final size/hash verification.
- Never overwrite or remove unrelated USB/SD contents.
- Release version is `0.3.16` and build number is `27`.
- Physical iPhone 14 Pro, Lightning adapter and USB/SD behavior remains a user-device verification boundary.

---

### Task 1: Persist receive decisions without treating them as completion

**Files:**
- Modify: `App/Receive/IPhoneReceiveApprovalStore.swift`
- Modify: `Tests/IPhoneReceiveApprovalStoreTests.swift`

**Interfaces:**
- Produces: `IPhoneReceiveArchiveMode`, `IPhoneReceiveDecision`, `decisions(receiverID:)`, and `approve(_:receiverID:decision:)`.
- Preserves: `destinations(receiverID:)` and `allowedDeliveryIDs(receiverID:destination:resuming:)` as derived compatibility APIs for the filtered clients.

- [ ] **Step 1: Write failing persistence and migration tests**

```swift
func testDecisionPersistsDestinationAndZIPMode() throws {
    let url = location()
    let receiver = UUID()
    let delivery = UUID()
    let store = IPhoneReceiveApprovalStore(fileURL: url)
    try store.approve([delivery], receiverID: receiver, decision: .init(
        destination: .usb,
        archiveMode: .extract
    ))

    let reopened = IPhoneReceiveApprovalStore(fileURL: url)
    XCTAssertEqual(
        try reopened.decisions(receiverID: receiver)[delivery],
        IPhoneReceiveDecision(destination: .usb, archiveMode: .extract)
    )
}

func testLegacyDestinationOnlyApprovalRequiresNewChoice() throws {
    let url = location()
    let receiver = UUID()
    let delivery = UUID()
    try legacyVersionOnePayload(receiver: receiver, delivery: delivery).write(to: url)

    let store = IPhoneReceiveApprovalStore(fileURL: url)
    XCTAssertTrue(try store.decisions(receiverID: receiver).isEmpty)
}
```

- [ ] **Step 2: Run the focused tests and verify RED in CI**

Run: push the tests to `codex/foreground-receive-alert` and run the `test.yml` workflow.

Expected: compilation fails because `IPhoneReceiveArchiveMode`, `IPhoneReceiveDecision`, and the decision-based approval API do not exist.

- [ ] **Step 3: Implement the version-two decision store**

```swift
enum IPhoneReceiveArchiveMode: String, Codable, Sendable, Equatable {
    case keepArchive
    case extract
}

struct IPhoneReceiveDecision: Codable, Sendable, Equatable {
    let destination: IPhoneReceiveDestination
    let archiveMode: IPhoneReceiveArchiveMode
}

private struct Approval: Codable {
    let receiverID: UUID
    let deliveryID: UUID
    let decision: IPhoneReceiveDecision
}
```

Decode `version == 2` normally. Decode a valid `version == 1` payload into an empty version-two state so destination-only records cannot silently choose ZIP behavior. Preserve corrupt/unknown-version fail-closed behavior. Keep the old destination-only `approve` overload and make it call the new API with `.keepArchive` so unrelated existing call sites remain source-compatible.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Expected: all `IPhoneReceiveApprovalStoreTests` pass, including reopening, receiver isolation, fallback override, corrupt data and legacy migration.

- [ ] **Step 5: Commit**

```text
git add App/Receive/IPhoneReceiveApprovalStore.swift Tests/IPhoneReceiveApprovalStoreTests.swift
git commit -m "feat: persist explicit ZIP receive decisions"
```

### Task 2: Re-offer incomplete files and model the two-stage prompt

**Files:**
- Modify: `App/UI/IPhoneIncomingFilesViewModel.swift`
- Modify: `App/Application/USBReceiverDependencies.swift`
- Modify: `Tests/IPhoneIncomingFilesViewModelTests.swift`

**Interfaces:**
- Consumes: `IPhoneReceiveDecision` from Task 1.
- Produces: `IPhoneIncomingPrompt` with `.archiveChoice` and `.destinationChoice` stages, `chooseArchiveMode(_:mode:)`, and `accept(_:decision:)`.

- [ ] **Step 1: Write failing activation and prompt-order tests**

```swift
func testPostponedBatchIsOfferedAgainAfterReactivationWithoutError() async throws {
    let context = try makeContext(count: 1)
    await activate(context)
    context.model.postponePrompt()
    XCTAssertNil(context.model.lastError)
    context.model.setActive(false)
    await activate(context)
    XCTAssertEqual(context.model.prompt?.files.count, 1)
}

func testApprovedButUnacknowledgedDeliveryIsOfferedOnNextActivation() async throws {
    let context = try makeContext(count: 1)
    await activate(context)
    let prompt = try XCTUnwrap(context.model.prompt)
    XCTAssertTrue(context.model.accept(prompt, decision: .init(
        destination: .usb,
        archiveMode: .keepArchive
    )))
    context.model.setActive(false)
    await activate(context)
    XCTAssertEqual(context.model.prompt?.files.count, 1)
}

func testZIPBatchAsksArchiveChoiceBeforeDestination() async throws {
    let context = try makeContext(count: 1)
    await activate(context)
    XCTAssertEqual(context.model.prompt?.stage, .archiveChoice)
    context.model.chooseArchiveMode(try XCTUnwrap(context.model.prompt), mode: .keepArchive)
    XCTAssertEqual(context.model.prompt?.stage, .destinationChoice(.keepArchive))
}
```

- [ ] **Step 2: Run the focused tests and verify RED in CI**

Expected: compilation fails because the staged prompt and decision APIs do not exist; the old activation test also demonstrates that `offeredIDs` remains populated.

- [ ] **Step 3: Implement the staged prompt and activation reset**

```swift
enum IPhoneIncomingPromptStage: Equatable {
    case archiveChoice
    case destinationChoice(IPhoneReceiveArchiveMode)
}

struct IPhoneIncomingPrompt: Identifiable, Equatable {
    let id = UUID()
    let batch: IPhoneIncomingBatch
    let stage: IPhoneIncomingPromptStage
    var files: [IPhoneDelivery] { batch.files }
}
```

On every transition to active, clear only `offeredIDs` and `acceptedIDs`. Keep the last server snapshot until the new query completes. Initial ZIP batches use `.archiveChoice`; non-ZIP batches use `.destinationChoice(.keepArchive)`. Selecting `.extract` immediately records a `.usb/.extract` decision. Selecting `.keepArchive` advances to destination choice without persisting. Dismissal calls `postponePrompt()` only.

In `makeIncomingFilesViewModel`, return every server `available` or `leased` delivery. Do not filter by approvals, local jobs or USB checkpoints; those records authorize/resume engines but do not prove completion. The active-session `acceptedIDs` set prevents a prompt loop while the receiver screen processes a chosen batch.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Expected: all incoming-model tests pass, including immutable batches, new arrivals, offline recovery, reactivation and approved-but-unacknowledged re-offer.

- [ ] **Step 5: Commit**

```text
git add App/UI/IPhoneIncomingFilesViewModel.swift App/Application/USBReceiverDependencies.swift Tests/IPhoneIncomingFilesViewModelTests.swift
git commit -m "fix: reoffer incomplete PC deliveries on activation"
```

### Task 3: Present ZIP handling before destination in SwiftUI

**Files:**
- Modify: `App/UI/ContentView.swift`
- Modify: `Tests/ForegroundReceiveContractTests.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`

**Interfaces:**
- Consumes: staged `IPhoneIncomingPrompt` from Task 2.
- Produces: separate archive and destination confirmation dialogs with stable accessibility identifiers.

- [ ] **Step 1: Write failing UI contract tests**

```swift
func testZIPChoicePrecedesDestinationAndCanBePostponed() throws {
    let root = try source("App/UI/ContentView.swift")
    XCTAssertTrue(root.contains("압축을 해제하시겠습니까?"))
    XCTAssertTrue(root.contains("압축 해제"))
    XCTAssertTrue(root.contains("ZIP 그대로 저장"))
    XCTAssertTrue(root.contains("수신 보류 · 앱을 다시 열면 다시 안내합니다."))
}
```

Add a UI simulation launch containing a ZIP and assert that destination buttons are absent until `ZIP 그대로 저장` is tapped. Add another launch that backgrounds/reactivates after postponement and assert that the arrival dialog reappears.

- [ ] **Step 2: Run the focused tests and verify RED in CI**

Expected: the contract assertion and ZIP UI flow fail because only the destination dialog exists.

- [ ] **Step 3: Implement two separate dialogs**

Render `.archiveChoice` as **압축을 해제하시겠습니까?** with `압축 해제`, `ZIP 그대로 저장`, and `나중에 받기`. Render `.destinationChoice` as the existing iPhone/USB choice. `압축 해제` calls the decision API with `.usb/.extract`, navigates to PC reception, and opens the USB folder picker when needed. `ZIP 그대로 저장` replaces the prompt with the destination stage. Both cancellation paths call `postponePrompt()` and show a neutral postponement message rather than changing `lastError`.

- [ ] **Step 4: Run contract and UI tests and verify GREEN**

Expected: staged dialog order, postponement and destination navigation all pass.

- [ ] **Step 5: Commit**

```text
git add App/UI/ContentView.swift Tests/ForegroundReceiveContractTests.swift UITests/ForegroundReceiveUITests.swift
git commit -m "feat: ask ZIP handling before receive destination"
```

### Task 4: Safely extract received ZIP files through private iPhone staging

**Files:**
- Create: `App/Receive/USBZIPReceivePipeline.swift`
- Create: `Tests/USBZIPReceivePipelineTests.swift`
- Modify: `App/Receive/USBReceiveLedger.swift`
- Modify: `App/Receive/USBReceiveProgress.swift`
- Modify: `App/Receive/USBReceiveService.swift`
- Modify: `App/Application/USBReceiverDependencies.swift`
- Modify: `App/UI/PCReceiveStatusView.swift`
- Modify: `Tests/USBReceiveLedgerTests.swift`
- Modify: `Tests/USBReceiveServiceTests.swift`

**Interfaces:**
- Consumes: `.extract` decisions and `SafeZIPExtractor`.
- Produces: `USBZIPReceivePipeline.commit(zip:delivery:destination:progress:) -> USBZIPCommit`, where the commit contains final folder name and verified extracted bytes.

- [ ] **Step 1: Write failing pipeline safety tests**

```swift
func testVerifiedZIPExtractsFromPrivateStagingAndCommitsFolder() throws {
    let result = try pipeline.commit(
        zip: privateZIP,
        delivery: delivery,
        destination: usbDestination,
        progress: { _ in }
    )
    XCTAssertEqual(result.finalFolderName, "업무자료")
    XCTAssertEqual(try Data(contentsOf: usb.appendingPathComponent("업무자료/a.txt")), Data("a".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: usb.appendingPathComponent("업무자료.zip").path))
}

func testCopyFailureRemovesOnlyAttemptPartialAndKeepsPrivateZIP() throws {
    XCTAssertThrowsError(try failingPipeline.commit(
        zip: privateZIP,
        delivery: delivery,
        destination: usbDestination,
        progress: { _ in }
    ))
    XCTAssertTrue(FileManager.default.fileExists(atPath: privateZIP.path))
    XCTAssertTrue(unrelatedUSBFileExists())
    XCTAssertFalse(attemptPartialExists())
}
```

Also test traversal/symlink rejection, duplicate final-folder suffixing, nested/hidden files, zero-byte files, per-file size/hash verification and unchanged unrelated USB contents.

- [ ] **Step 2: Run pipeline tests and verify RED in CI**

Expected: compilation fails because `USBZIPReceivePipeline` and `USBZIPCommit` do not exist.

- [ ] **Step 3: Implement the isolated ZIP commit pipeline**

Use `SafeZIPExtractor` to extract into a unique private directory beside the staged ZIP. Create a unique hidden USB partial directory under `.SimpleCameraReceiver`, reproduce directories, stream-copy every extracted file while computing SHA-256, and verify the final tree before moving the partial directory to an available final folder. A `defer` removes private extraction and the attempt partial; it never removes the source ZIP. Return only after the final folder is verified.

- [ ] **Step 4: Extend resumable USB reception**

Add `archiveMode` to `USBReceiveCheckpoint` with custom decoding defaulting legacy checkpoints to `.keepArchive`. Add a private iPhone ZIP staging directory and a receive-decision provider to `USBReceiveService`. For `.extract`, range-download and hash the ZIP in private staging, call `USBZIPReceivePipeline`, set the checkpoint to `.ackPending`, ACK the final folder name, then remove the private ZIP and checkpoint. If final output exists after interruption, re-extract privately and verify it before retrying ACK. For `.keepArchive`, retain the current direct USB file behavior unchanged.

Add `.extracting` to `USBReceiveStage`, publish separate download/extract/copy/verify progress, and map it to `압축 해제 중` in the status view.

- [ ] **Step 5: Run focused service and ledger tests and verify GREEN**

Expected: existing plain-file resume/ACK tests remain green; new extraction, interrupted-copy, interrupted-ACK, legacy-checkpoint and cleanup tests pass.

- [ ] **Step 6: Commit**

```text
git add App/Receive/USBZIPReceivePipeline.swift App/Receive/USBReceiveLedger.swift App/Receive/USBReceiveProgress.swift App/Receive/USBReceiveService.swift App/Application/USBReceiverDependencies.swift App/UI/PCReceiveStatusView.swift Tests/USBZIPReceivePipelineTests.swift Tests/USBReceiveLedgerTests.swift Tests/USBReceiveServiceTests.swift
git commit -m "feat: extract received ZIP files safely to USB"
```

### Task 5: Full regression, version and SideStore release

**Files:**
- Modify: `project.yml`
- Modify: `README.md`
- Modify: `docs/install.md`
- Modify: `Tests/ProjectSmokeTests.swift`

**Interfaces:**
- Consumes: completed receive state machine and ZIP pipeline.
- Produces: version `0.3.16` build `27`, verified unsigned IPA, SideStore QR and release assets.

- [ ] **Step 1: Add failing smoke assertions**

Assert `MARKETING_VERSION: 0.3.16`, `CURRENT_PROJECT_VERSION: 27`, the ZIP-choice labels, repeat-on-activation behavior documentation, and exact ZIPFoundation `0.9.20`.

- [ ] **Step 2: Run smoke tests and verify RED**

Expected: version/documentation assertions fail while the project remains `0.3.15` (26).

- [ ] **Step 3: Update version and documentation**

Update only the final version component and build number. Document that `압축 해제` uses temporary iPhone storage, commits verified extracted output to USB/SD, and that dismissed/incomplete files are re-offered when the app becomes active.

- [ ] **Step 4: Run full CI and verify GREEN**

Run the repository `test.yml` workflow. Require all logic and UI tests, UI screenshot export, unsigned IPA build and artifact upload to succeed. Run `scripts/verify-ipa.py`, verify bundle version/build, ZIP CRC and `scripts/generate-install-qr.py --check` against the CI artifact.

- [ ] **Step 5: Tag and publish only the tested commit**

```text
git tag -a v0.3.16 -m "SimpleCameraAutoSender 0.3.16"
git push origin v0.3.16
```

Require the release workflow to pass all tests again, generate `SimpleCameraAutoSender.ipa` and `install-qr.png`, and publish the release. Download those exact release assets to the Desktop with versioned names, compare their GitHub digests, and report the physical-device test boundary.

