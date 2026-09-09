# Deletion progress and receipt recovery implementation plan

> Execute inline in the existing codex worktree using executing-plans and TDD.

**Goal:** Report real deletion progress and recover verified-file ACK failures without
redownloading or discarding originals.

**Architecture:** Synchronous filesystem callbacks publish immutable count snapshots.
Per-operation AsyncStream forwards snapshots to the main actor and is drained before
ending the operation, so late callbacks cannot overwrite a completed/new operation.
Persist receipt-pending independently from failed download.

**Tech Stack:** SwiftUI, Foundation, XCTest, Cloudflare Worker/D1; existing macOS CI.

## Constraints
No user-file testing/deletion, no SHA bypass, no guessed filesystem, Chrome only.

## Tasks
- [ ] Add regressions in IPhoneStoredFileDeletionTests, USBFolderCleanupServiceTests
  and IPhoneLocalReceiveEngineTests. Assert processed counts 0/1/2, true failure count,
  no false failure when removal succeeded, and ACK rejection is not download failure.
  Run the existing GitHub CI with test-only changes and callback scaffolding; record red.
- [ ] Add FileDeletionProgress and callbacks to catalog and cleanup service. Wire
  dependencies, VM streams and a shared SwiftUI progress view. Drain stream before
  completing the operation; retain errors separately. Reconcile final inventory.
- [ ] Read filesystem metadata inside balanced security scope. Add tests with scope
  probe and nil metadata. Display unsupported metadata separately from unavailable USB.
- [ ] Add receipt-pending stage/outcome after successful final verification only;
  refresh the stored-file list at this state; keep retries and validation intact.
  Test real local file and catalog surviving an HTTP 409 then successful ACK.
- [ ] Authenticate Cloudflare, read matching delivery state and deployed Worker source.
  Write server regression for the confirmed failure before patching that source.
  Do not change canceled/expired semantics without validating why the state changed.
- [ ] Run full CI/iOS26 tests and build, inspect artifacts/version, then deliver IPA/QR.
  Report live server/device limits explicitly if authentication is unavailable.
