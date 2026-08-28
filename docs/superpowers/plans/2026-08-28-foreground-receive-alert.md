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

- [x] Add failing source-wiring contracts for root-owned monitoring, destination
  filtering and fallback approval. These supplement behavioral tests, not replace them.
- [x] Commit tests on `codex/foreground-receive-alert`, push and inspect CI.

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
`Tests/IPhoneReceiveApprovalStoreTests.swift`, `Tests/ApprovedReceiveIntegrationTests.swift`.

Interfaces:

```swift
func destinations(receiverID: UUID) throws -> [UUID: IPhoneReceiveDestination]
func approve(_ ids: Set<UUID>, receiverID: UUID, destination: IPhoneReceiveDestination) throws
// Client initializer: optional allowed-ID provider; nil means discovery-only unfiltered list.
typealias AllowedDeliveryIDs = @Sendable (UUID) throws -> Set<UUID>?
```

- [x] Write persistence, receiver isolation, corrupt-store and two-destination tests.
- [x] Implement lock-protected atomic decisions; a write failure must not grant access.
- [x] Test a real client with a fake transport: no approved IDs returns an empty list;
  approved IDs return only the chosen batch, regardless of new server items.
- [x] Wire separate filtered clients for local and USB; preserve existing started jobs.

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

- [x] Write real-model tests using an injected list provider and real approval store.
- [x] Cover 10 files, no automatic approval, frozen batches, duplicate checks,
  postponement/manual reopening, offline recovery and ignoring a late background response.
- [x] Implement a root-owned one-second nonoverlapping monitor with explicit errors.
- [x] Add root arrival choice, pending count/reopen controls and route to receiver.
- [x] Keep USB fallback limited to approved IDs and reset server-wait after valid folder selection.
- [x] Refresh the local saved-files list on receive completion so completed files are visible.

## Task 4: Re-entrancy and full simulator regression

Files: `App/Receive/IPhoneLocalReceiveEngine.swift`, `App/Receive/USBReceiveService.swift`,
`Tests/ApprovedReceiveIntegrationTests.swift`, `UITests/ForegroundReceiveUITests.swift`.

- [x] Reproduce concurrent discovery with suspended fake network responses.
- [x] Guard an in-flight operation before its first `await`, releasing with `defer`.
- [x] Run all XCTest tests on macOS using `bash scripts/test-ios.sh` in CI.
- [x] Inspect every failure and re-run after fixes; do not weaken safety assertions.

## Task 5: Build and verify the IPA

Files: `project.yml`, `Tests/ProjectSmokeTests.swift`, `docs/install.md`.

- [x] Update version/build contract and document foreground-only arrival behavior.
- [x] Run simulator suite and `bash scripts/build-unsigned-ipa.sh` in CI.
- [x] Download the successful artifact, inspect Info.plist and ZIP CRC, compute SHA-256.
- [x] Hand off the new IPA and clearly separate simulator coverage from untested physical USB behavior.

## Self-review

Every new receive entry point is filtered; old jobs remain resumable. File IDs
are scoped to the registered receiver. Prompt selection uses a fixed batch, not
the later refreshed inbox. Background suspension never triggers a download based
on an unseen prompt. Existing photo upload and server acknowledgement rules are unchanged.

## Reproduction evidence

- CI 33129394478: new foreground wiring contracts failed; the original 155 tests passed.
- CI 33130242916: 184 tests ran; only two re-entrant receive tests failed.
- CI 33130629354: frozen USB fallback selection and unapplied destination pickers reproduced.
- CI 33131027315: 190 logic tests and two UI tests passed; a candidate IPA built successfully.
- CI 33131607777: adding USB picker/cancellation coverage exposed a stale USB destination label after choosing iPhone fallback. The system picker and fallback alert themselves opened successfully.
- Simulator UI fixtures are isolated to `DEBUG && targetEnvironment(simulator)`; no relay access, user photos or real Keychain registration are used.
- Final CI 33131959088: 190 logic tests + 3 actual UI tests passed, with zero failures. Release IPA built from commit `622132654d5f2302e864cb681dbfbe45c8af8804`.
- The published v0.3.4 IPA and anonymous `releases/latest/download` both match SHA-256 `25cb91aabd2f127cce8c4cc2c94c0895eef864e319ba7531c87d09e5141e28e8`.
