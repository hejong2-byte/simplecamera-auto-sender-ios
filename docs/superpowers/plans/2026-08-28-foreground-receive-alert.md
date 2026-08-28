# Foreground Receive Alert Implementation Plan

> **For agentic workers:** Use executing-plans inline. The user's workspace rules prohibit unsolicited parallel agents.

**Goal:** Show incoming PC files across the foreground app and receive only the batch explicitly approved for iPhone or USB.

**Architecture:** A root-owned read-only monitor presents immutable batches. Atomic receiver-scoped decisions filter the existing clients used by the receive engines, including restoration. Existing transfer/verification code stays responsible for writing and acknowledgement.

**Tech Stack:** Swift 5, SwiftUI, Foundation, XCTest, XcodeGen, macOS GitHub Actions.

## Global Constraints

- iOS 17.0, bundle `com.hejong2byte.simplecameraautosender`.
- Version 0.3.4, build 15; same registration, bookmark, ledger and document paths.
- Foreground arrival alert only; do not claim closed-app push support.
- No production file transfers or Worker changes during tests.
- Only selected IDs may inherit a destination. Preserve originals on failure.

## Task 1: Reproduce the missing foreground/approval contracts

Files: `Tests/ForegroundReceiveContractTests.swift`.

- [ ] Add failing source-wiring contracts for root-owned monitoring, destination
  filtering and fallback approval. These supplement behavioral tests, not replace them.
- [ ] Commit tests on `codex/foreground-receive-alert`, push and inspect CI.

```swift
XCTAssertTrue(root.contains("incomingModel.setActive"))
XCTAssertTrue(dependencies.contains("allowedDeliveryIDs:"))
XCTAssertTrue(receiverModel.contains("approveLocalFallback"))
```

Command: `gh run list --repo hejong2-byte/simplecamera-auto-sender-ios --branch codex/foreground-receive-alert`.
Expected: tests compile and fail these missing contracts; no release is published.

## Task 2: Persist explicit choices and gate both clients

Files: `App/Receive/IPhoneReceiveApprovalStore.swift`,
`App/Receive/IPhoneReceiverClient.swift`, `App/Application/USBReceiverDependencies.swift`,
`Tests/IPhoneReceiveApprovalStoreTests.swift`, `Tests/IPhoneReceiverClientTests.swift`.

Interfaces:

```swift
func destinations(receiverID: UUID) throws -> [UUID: IPhoneReceiveDestination]
func approve(_ ids: Set<UUID>, receiverID: UUID, destination: IPhoneReceiveDestination) throws
// Client initializer: optional allowed-ID provider; nil means discovery-only unfiltered list.
typealias AllowedDeliveryIDs = @Sendable (UUID) throws -> Set<UUID>?
```

- [ ] Write persistence, receiver isolation, corrupt-store and two-destination tests.
- [ ] Implement lock-protected atomic decisions; a write failure must not grant access.
- [ ] Test a real client with a fake transport: no approved IDs returns an empty list;
  approved IDs return only the chosen batch, regardless of new server items.
- [ ] Wire separate filtered clients for local and USB; preserve existing started jobs.

## Task 3: Monitor, present and route foreground arrivals

Files: `App/UI/IPhoneIncomingFilesViewModel.swift`, `App/UI/ContentView.swift`,
`App/UI/USBReceiverView.swift`, `App/UI/USBReceiverViewModel.swift`,
`App/Application/SimpleCameraAutoSenderApp.swift`,
`Tests/IPhoneIncomingFilesViewModelTests.swift`, `Tests/USBReceiverViewModelTests.swift`.

Interfaces:

```swift
func setActive(_ active: Bool)
func refresh() async
func showPendingFiles()
func postponePrompt()
func accept(_ batch: IPhoneIncomingBatch, destination: IPhoneReceiveDestination) -> Bool
```

- [ ] Write real-model tests using an injected list provider and real approval store.
- [ ] Cover 10 files, no automatic approval, frozen batches, duplicate checks,
  postponement/manual reopening, offline recovery and ignoring a late background response.
- [ ] Implement a root-owned one-second nonoverlapping monitor with explicit errors.
- [ ] Add root arrival choice, pending count/reopen controls and route to receiver.
- [ ] Keep USB fallback limited to approved IDs and reset server-wait after valid folder selection.
- [ ] Refresh the local saved-files list on receive completion so completed files are visible.

## Task 4: Re-entrancy and full simulator regression

Files: `App/Receive/IPhoneLocalReceiveEngine.swift`, `App/Receive/USBReceiveService.swift`,
`Tests/IPhoneLocalReceiveEngineTests.swift`, `Tests/USBReceiveServiceTests.swift`.

- [ ] Reproduce concurrent discovery with suspended fake network responses.
- [ ] Guard an in-flight operation before its first `await`, releasing with `defer`.
- [ ] Run all XCTest tests on macOS using `bash scripts/test-ios.sh` in CI.
- [ ] Inspect every failure and re-run after fixes; do not weaken safety assertions.

## Task 5: Build and verify the IPA

Files: `project.yml`, `Tests/ProjectSmokeTests.swift`, `docs/install.md`.

- [ ] Update version/build contract and document foreground-only arrival behavior.
- [ ] Run simulator suite and `bash scripts/build-unsigned-ipa.sh` in CI.
- [ ] Download the successful artifact, inspect Info.plist and ZIP CRC, compute SHA-256.
- [ ] Hand off the new IPA and clearly separate simulator coverage from untested physical USB behavior.

## Self-review

Every new receive entry point is filtered; old jobs remain resumable. File IDs
are scoped to the registered receiver. Prompt selection uses a fixed batch, not
the later refreshed inbox. Background suspension never triggers a download based
on an unseen prompt. Existing photo upload and server acknowledgement rules are unchanged.
