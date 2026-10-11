import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class TransferNotificationTests: XCTestCase {
    func testDefaultOffDoesNotRequestPermissionOrSchedule() async throws {
        let fixture = try makeFixture(status: .authorized)
        await fixture.service.refreshAuthorization()
        await fixture.service.handle(event(.completed))
        XCTAssertFalse(fixture.preferences.transferNotificationsEnabled)
        await assertPermissionCount(0, fixture.client)
        await assertRequestCount(0, fixture.client)
    }

    func testEnablingRequestsPermissionOnceAndPersistsPreference() async throws {
        let fixture = try makeFixture(status: .notDetermined)
        await fixture.service.setEnabled(true)
        XCTAssertTrue(fixture.preferences.transferNotificationsEnabled)
        XCTAssertTrue(fixture.service.isReady)
        await assertPermissionCount(1, fixture.client)
        await fixture.service.refreshAuthorization()
        await assertPermissionCount(1, fixture.client)
        await fixture.service.setEnabled(false)
        XCTAssertFalse(fixture.preferences.transferNotificationsEnabled)
    }

    func testPersistedOptInSchedulesFromFreshServiceWithoutOpeningSettings() async throws {
        let fixture = try makeFixture(status: .authorized)
        fixture.preferences.transferNotificationsEnabled = true
        let restarted = TransferNotificationService(preferences: fixture.preferences, client: fixture.client)
        XCTAssertFalse(restarted.isReady)
        await restarted.handle(event(.completed))
        await assertRequestCount(1, fixture.client)
        await assertPermissionCount(0, fixture.client)
        XCTAssertTrue(restarted.isReady)
    }

    func testDisablingWhilePermissionIsPendingCannotReenableOrReplayOldEvents() async throws {
        let suite = "DelayedNotificationPermission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = USBReceiverPreferences(defaults: defaults)
        let requested = expectation(description: "permission request is pending")
        let client = DelayedPermissionNotificationClient(onRequest: { requested.fulfill() })
        let service = TransferNotificationService(preferences: preferences, client: client)
        let enabling = Task { await service.setEnabled(true) }
        await fulfillment(of: [requested], timeout: 2)
        await service.handle(event(.completed))
        await service.setEnabled(false)
        await client.resolvePermission(true)
        await enabling.value
        XCTAssertFalse(preferences.transferNotificationsEnabled)
        XCTAssertFalse(service.isReady)
        XCTAssertTrue(service.readinessMessage.contains("꺼짐"))
        let requests = await client.requests()
        XCTAssertTrue(requests.isEmpty, "Late OS permission must not schedule an old event or undo the opt-out")
    }

    func testDeniedAndRevokedPermissionShowsReadinessWithoutBlockingTransfer() async throws {
        let fixture = try makeFixture(status: .denied)
        await fixture.service.setEnabled(true)
        XCTAssertTrue(fixture.preferences.transferNotificationsEnabled)
        XCTAssertFalse(fixture.service.isReady)
        XCTAssertTrue(fixture.service.canOpenSettings)
        XCTAssertTrue(fixture.service.readinessMessage.contains("차단"))
        await fixture.service.handle(event(.completed))
        await assertRequestCount(0, fixture.client)
        await fixture.client.setStatus(.authorized)
        await fixture.service.refreshAuthorization()
        XCTAssertTrue(fixture.service.isReady)
        await fixture.client.setStatus(.denied)
        await fixture.service.refreshAuthorization()
        XCTAssertFalse(fixture.service.isReady)
    }

    func testCompletionFailureAndInvoluntaryPauseUseGenericBodiesAndStableIDs() async throws {
        let fixture = try makeFixture(status: .authorized)
        await fixture.service.setEnabled(true)
        let completion = event(.completed)
        await fixture.service.handle(completion)
        await fixture.service.handle(completion)
        await fixture.service.handle(event(.failed))
        await fixture.service.handle(event(.paused))
        let requests = await fixture.client.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map(\.identifier)).count, 3)
        XCTAssertTrue(requests.allSatisfy { !$0.body.contains("secret.pdf") && !$0.body.contains("123456") })
        XCTAssertTrue(requests.allSatisfy { $0.body.contains("개") })
    }

    func testFailureThenResumeSuccessForSameJobIsEligibleWithoutDuplicateEvents() async throws {
        let fixture = try makeFixture(status: .authorized)
        await fixture.service.setEnabled(true)
        let id = "delivery-\(UUID().uuidString)"
        await fixture.service.handle(event(.failed, id: id))
        await fixture.service.handle(event(.failed, id: id))
        await fixture.service.handle(event(.completed, id: id))
        await fixture.service.handle(event(.completed, id: id))
        await assertRequestCount(2, fixture.client)
    }

    func testDisabledEventsAndEmptyOrUserCancelledJobsCannotReplayAfterEnabling() async throws {
        let fixture = try makeFixture(status: .authorized)
        let old = event(.completed)
        await fixture.service.handle(old)
        await fixture.service.setEnabled(true)
        await fixture.service.handle(old)
        await fixture.service.handle(event(.completed, count: 0))
        await fixture.service.handle(event(.cancelled))
        await assertRequestCount(0, fixture.client)
        await fixture.service.handle(event(.completed))
        await assertRequestCount(1, fixture.client)
    }

    func testSequentialRealJobsAreNotSuppressedBySameOutcome() async throws {
        let fixture = try makeFixture(status: .authorized)
        await fixture.service.setEnabled(true)
        for _ in 0..<8 { await fixture.service.handle(event(.completed)) }
        await assertRequestCount(8, fixture.client)
    }

    func testSchedulingFailureChangesNotificationReadinessOnly() async throws {
        let fixture = try makeFixture(status: .authorized)
        await fixture.service.setEnabled(true)
        await fixture.client.failScheduling()
        await fixture.service.handle(event(.completed))
        XCTAssertTrue(fixture.service.readinessMessage.contains("알림"))
        XCTAssertTrue(fixture.service.readinessMessage.contains("실패"))
        XCTAssertTrue(fixture.preferences.transferNotificationsEnabled)
        await assertRequestCount(0, fixture.client)
    }

    func testNotificationSchedulingFailureCannotFailRealUSBExport() async throws {
        let fixture = try makeFixture(status: .authorized)
        await fixture.service.setEnabled(true)
        await fixture.client.failScheduling()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let usb = root.appendingPathComponent("usb")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.pdf")
        let bytes = Data("USB copy remains successful".utf8)
        try bytes.write(to: source)
        let file = IPhoneStoredFile(id: source.path, url: source, name: "original.pdf", size: Int64(bytes.count),
            modifiedAt: Date(), receivedRecord: nil)
        let store = USBReceiveProgressStore()
        let schedulingFinished = expectation(description: "notification scheduling attempt finishes separately")
        let notifications = fixture.service
        store.setTransferEventHandler { event in
            Task { @MainActor in
                await notifications.handle(event)
                schedulingFinished.fulfill()
            }
        }
        let exporter = IPhoneUSBExportService(deletionStore: try IPhoneUSBDeletionDecisionStore(fileURL: root.appendingPathComponent("decisions.json")),
            startAccessing: { _ in true }, stopAccessing: { _ in }, volumeIdentity: { _ in "notification-volume" },
            progressStore: store, zipWorkingDirectory: root.appendingPathComponent("zip-work"), capacityQuery: { _ in nil })
        let destination = USBBookmarkDestination(url: usb, volumeID: "notification-volume", displayName: "Test USB", isStale: false)
        store.beginExport(fileName: file.name, totalCount: 1)
        let result = await exporter.export([file], to: destination, archiveMode: .keepArchive)
        XCTAssertTrue(result.failed.isEmpty, result.errorMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: usb.appendingPathComponent(file.name)), bytes)
        await fulfillment(of: [schedulingFinished], timeout: 3)
        XCTAssertEqual(store.snapshot().stage, .completed)
        XCTAssertTrue(fixture.service.readinessMessage.contains("실패"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testProgressStoreDoesNotReplayTerminalSnapshotWhenHookIsInstalled() throws {
        let store = USBReceiveProgressStore()
        store.beginExport(fileName: "secret.pdf", totalCount: 1)
        store.publish(progress(.completed))
        let events = NotificationEventRecorder()
        store.setTransferEventHandler { events.append($0) }
        XCTAssertTrue(events.values.isEmpty)
        store.publish(progress(.completed))
        XCTAssertTrue(events.values.isEmpty)
        store.beginExport(fileName: "next.pdf", totalCount: 1)
        store.publish(progress(.completed))
        XCTAssertEqual(events.values.count, 1)
    }

    func testRealManualOverwriteApprovalAndCancellationAreSilentButApprovedCopyNotifies() async throws {
        let fixture = try makeExportFixture()
        let oldBytes = Data("existing USB original".utf8)
        let target = fixture.destination.url.appendingPathComponent(fixture.file.name)
        try oldBytes.write(to: target)
        fixture.store.beginExport(fileName: fixture.file.name, totalCount: 1)
        let pending = await fixture.exporter.export([fixture.file], to: fixture.destination, archiveMode: .keepArchive)
        XCTAssertEqual(pending.failed.map(\.error), [.overwriteConfirmationRequired])
        XCTAssertEqual(fixture.store.snapshot().stage, .failed, "Approval UI keeps its existing progress contract")
        XCTAssertTrue(fixture.events.values.isEmpty, "An approval request is not a failed USB copy")
        fixture.store.publish(progress(.cancelled))
        XCTAssertTrue(fixture.events.values.isEmpty, "Declining overwrite must remain silent")
        XCTAssertEqual(try Data(contentsOf: target), oldBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.file.url), fixture.bytes)

        fixture.store.beginExport(fileName: fixture.file.name, totalCount: 1)
        let approved = await fixture.exporter.export([fixture.file], to: fixture.destination,
            archiveMode: .keepArchive, overwriteExisting: true)
        XCTAssertTrue(approved.failed.isEmpty, approved.errorMessage ?? "")
        XCTAssertEqual(fixture.events.values.map(\.outcome), [.completed])
        XCTAssertEqual(try Data(contentsOf: target), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.file.url), fixture.bytes)
    }

    func testRealManualMixedOverwriteApprovalAndMissingSourceStillNotifiesFailure() async throws {
        let fixture = try makeExportFixture()
        let target = fixture.destination.url.appendingPathComponent(fixture.file.name)
        let oldBytes = Data("existing USB original".utf8)
        try oldBytes.write(to: target)
        let missingURL = fixture.file.url.deletingLastPathComponent().appendingPathComponent("missing.pdf")
        let missing = IPhoneStoredFile(id: missingURL.path, url: missingURL, name: "missing.pdf", size: 10,
            modifiedAt: Date(), receivedRecord: nil)
        fixture.store.beginExport(fileName: fixture.file.name, totalCount: 2)
        let result = await fixture.exporter.export([fixture.file, missing], to: fixture.destination, archiveMode: .keepArchive)
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertEqual(result.failed.first?.error, .overwriteConfirmationRequired)
        XCTAssertNotEqual(result.failed.last?.error, .overwriteConfirmationRequired)
        XCTAssertEqual(fixture.events.values.map(\.outcome), [.failed])
        XCTAssertEqual(try Data(contentsOf: target), oldBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.file.url), fixture.bytes)
    }

    private func makeExportFixture() throws -> (exporter: IPhoneUSBExportService, store: USBReceiveProgressStore,
        destination: USBBookmarkDestination, file: IPhoneStoredFile, bytes: Data, events: NotificationEventRecorder) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let usb = root.appendingPathComponent("usb")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.pdf")
        let bytes = Data("new iPhone original".utf8)
        try bytes.write(to: source)
        let file = IPhoneStoredFile(id: source.path, url: source, name: source.lastPathComponent, size: Int64(bytes.count),
            modifiedAt: Date(), receivedRecord: nil)
        let store = USBReceiveProgressStore()
        let events = NotificationEventRecorder()
        store.setTransferEventHandler { events.append($0) }
        let exporter = IPhoneUSBExportService(deletionStore: try IPhoneUSBDeletionDecisionStore(fileURL: root.appendingPathComponent("decisions.json")),
            startAccessing: { _ in true }, stopAccessing: { _ in }, volumeIdentity: { _ in "notification-volume" },
            progressStore: store, zipWorkingDirectory: root.appendingPathComponent("zip-work"), capacityQuery: { _ in nil })
        return (exporter, store, USBBookmarkDestination(url: usb, volumeID: "notification-volume", displayName: "Test USB", isStale: false),
            file, bytes, events)
    }

    func testProgressHookRunsOutsideLockAndManualVerificationDiscoveryCancelAreSilent() throws {
        let store = USBReceiveProgressStore()
        let events = NotificationEventRecorder()
        store.setTransferEventHandler { event in
            _ = store.snapshot()
            events.append(event)
        }
        store.publishDiscoveryFailure("network", destination: .usb)
        store.publish(progress(.verifying))
        store.publish(progress(.completed))
        XCTAssertTrue(events.values.isEmpty)
        store.beginExport(fileName: "cancel.pdf", totalCount: 1)
        store.publish(progress(.cancelled))
        XCTAssertTrue(events.values.isEmpty)
        store.beginExport(fileName: "paused.pdf", totalCount: 1)
        store.interruptExport()
        XCTAssertEqual(events.values.map(\.outcome), [.paused])
    }

    private func assertRequestCount(_ expected: Int, _ client: TestNotificationClient, file: StaticString = #filePath, line: UInt = #line) async {
        let requests = await client.requests()
        XCTAssertEqual(requests.count, expected, file: file, line: line)
    }

    private func assertPermissionCount(_ expected: Int, _ client: TestNotificationClient, file: StaticString = #filePath, line: UInt = #line) async {
        let count = await client.permissionRequests()
        XCTAssertEqual(count, expected, file: file, line: line)
    }

    private func event(_ outcome: TransferNotificationOutcome, id: String = UUID().uuidString, count: Int = 1) -> TransferNotificationEvent {
        TransferNotificationEvent(jobID: id, operation: .receive, outcome: outcome, count: count)
    }

    private func progress(_ stage: USBReceiveStage) -> USBReceiveProgress {
        USBReceiveProgress(stage: stage, deliveryID: nil, fileName: "secret.pdf", currentIndex: 1, totalCount: 1,
            completedCount: stage == .completed ? 1 : 0, bytesReceived: 10, totalBytes: 10,
            startedAt: nil, expiresAt: nil, errorMessage: stage == .failed ? "failure" : nil)
    }

    private func makeFixture(status: TransferNotificationAuthorization) throws -> NotificationFixture {
        let suite = "TransferNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = USBReceiverPreferences(defaults: defaults)
        let client = TestNotificationClient(status: status)
        return NotificationFixture(preferences: preferences, client: client,
            service: TransferNotificationService(preferences: preferences, client: client))
    }
}

private struct NotificationFixture {
    let preferences: USBReceiverPreferences
    let client: TestNotificationClient
    let service: TransferNotificationService
}

private actor TestNotificationClient: TransferNotificationClient {
    private var status: TransferNotificationAuthorization
    private var permissionCount = 0
    private var scheduled: [TransferNotificationRequest] = []
    private var schedulingFails = false
    init(status: TransferNotificationAuthorization) { self.status = status }
    func authorizationStatus() async -> TransferNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        permissionCount += 1
        if status == .notDetermined { status = .authorized }
        return status == .authorized
    }
    func schedule(_ request: TransferNotificationRequest) async throws {
        if schedulingFails { throw CocoaError(.featureUnsupported) }
        scheduled.append(request)
    }
    func setStatus(_ value: TransferNotificationAuthorization) { status = value }
    func failScheduling() { schedulingFails = true }
    func requests() -> [TransferNotificationRequest] { scheduled }
    func permissionRequests() -> Int { permissionCount }
}

private actor DelayedPermissionNotificationClient: TransferNotificationClient {
    private let onRequest: @Sendable () -> Void
    private var pending: CheckedContinuation<Bool, Never>?
    private var authorization = TransferNotificationAuthorization.notDetermined
    private var scheduled: [TransferNotificationRequest] = []
    init(onRequest: @escaping @Sendable () -> Void) { self.onRequest = onRequest }
    func authorizationStatus() async -> TransferNotificationAuthorization { authorization }
    func requestAuthorization() async throws -> Bool {
        await withCheckedContinuation { continuation in
            pending = continuation
            onRequest()
        }
    }
    func resolvePermission(_ granted: Bool) {
        authorization = granted ? .authorized : .denied
        pending?.resume(returning: granted)
        pending = nil
    }
    func schedule(_ request: TransferNotificationRequest) async throws { scheduled.append(request) }
    func requests() -> [TransferNotificationRequest] { scheduled }
}

private final class NotificationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TransferNotificationEvent] = []
    var values: [TransferNotificationEvent] { lock.withLock { recorded } }
    func append(_ value: TransferNotificationEvent) { lock.withLock { recorded.append(value) } }
}
