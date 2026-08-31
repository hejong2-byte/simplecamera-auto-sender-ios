import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverManualDeletionTests: XCTestCase {
    func testCancellationDoesNotDeleteAnyFile() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)
        fixture.model.requestStoredFileDeletion()
        XCTAssertTrue(fixture.model.needsStoredFileDeletionConfirmation)

        fixture.model.cancelStoredFileDeletion()
        await fixture.model.deleteConfirmedStoredFiles()

        XCTAssertFalse(fixture.model.needsStoredFileDeletionConfirmation)
        XCTAssertEqual(try fixture.catalog.refresh().count, 2)
        XCTAssertNil(fixture.model.storedFileDeletionMessage)
    }

    func testOnlyConfirmedSelectionIsDeletedAndListRefreshesImmediately() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let first = try XCTUnwrap(fixture.model.storedFiles.first { $0.name == "first.txt" })
        let second = try XCTUnwrap(fixture.model.storedFiles.first { $0.name == "second.txt" })
        fixture.model.toggleStoredFileSelection(first.id)
        fixture.model.requestStoredFileDeletion()
        fixture.model.toggleStoredFileSelection(second.id)

        await fixture.model.deleteConfirmedStoredFiles()

        XCTAssertEqual(fixture.model.storedFiles.map(\.name), ["second.txt"])
        XCTAssertFalse(fixture.model.selectedStoredFileIDs.contains(first.id))
        XCTAssertFalse(fixture.model.needsStoredFileDeletionConfirmation)
        XCTAssertEqual(fixture.model.storedFileDeletionMessage, "iPhone 파일 1개 삭제 완료")
        XCTAssertNil(fixture.model.storedFileDeletionError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testDeletionWithoutConfirmationDoesNothing() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)

        await fixture.model.deleteConfirmedStoredFiles()

        XCTAssertEqual(try fixture.catalog.refresh().count, 2)
        XCTAssertNil(fixture.model.storedFileDeletionMessage)
    }

    func testPartialFailureKeepsFailedFileSelectedAndShowsActualCounts() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        for file in fixture.model.storedFiles {
            fixture.model.toggleStoredFileSelection(file.id)
        }
        fixture.model.requestStoredFileDeletion()
        let changed = try XCTUnwrap(fixture.model.storedFiles.first { $0.name == "second.txt" })
        try Data("changed after confirmation".utf8).write(to: changed.url)

        await fixture.model.deleteConfirmedStoredFiles()

        XCTAssertEqual(fixture.model.storedFiles.map(\.id), [changed.id])
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, [changed.id])
        XCTAssertEqual(fixture.model.storedFileDeletionMessage, "iPhone 파일 1개 삭제 완료")
        XCTAssertTrue(fixture.model.storedFileDeletionError?.contains("1개 삭제 실패") == true)
        XCTAssertTrue(fixture.model.storedFileDeletionError?.contains("second.txt") == true)
        XCTAssertNil(fixture.model.lastError, "Local deletion must not become a PC receive error")
    }

    func testActiveReceiveBlocksDeletionConfirmation() async throws {
        let progress = USBReceiveProgressStore()
        let fixture = try makeFixture(progress: progress)
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)
        progress.publish(USBReceiveProgress(
            stage: .downloading, destination: .iphoneLocal, deliveryID: UUID(),
            fileName: "incoming.zip", currentIndex: 1, totalCount: 1, completedCount: 0,
            bytesReceived: 1, totalBytes: 10, startedAt: .now,
            expiresAt: nil, errorMessage: nil
        ))
        await waitUntil { fixture.model.isReceivingFile }

        fixture.model.requestStoredFileDeletion()

        XCTAssertFalse(fixture.model.needsStoredFileDeletionConfirmation)
        XCTAssertEqual(try fixture.catalog.refresh().count, 2)
    }

    func testRepeatedConfirmationCannotStartTwoDeletes() async throws {
        let gate = StoredDeletionGate()
        let fixture = try makeFixture(beforeDelete: { await gate.wait() })
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)
        fixture.model.requestStoredFileDeletion()
        let deletion = Task { await fixture.model.deleteConfirmedStoredFiles() }
        await waitUntil { fixture.model.isDeletingStoredFiles }

        fixture.model.requestStoredFileDeletion()
        await fixture.model.deleteConfirmedStoredFiles()
        await gate.release()
        await deletion.value
        let calls = await gate.callCount

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try fixture.catalog.refresh().count, 1)
        XCTAssertFalse(fixture.model.isDeletingStoredFiles)
    }

    private func makeFixture(
        progress: USBReceiveProgressStore = USBReceiveProgressStore(),
        beforeDelete: @escaping @Sendable () async -> Void = {}
    ) throws -> (model: USBReceiverViewModel, catalog: IPhoneReceivedFileCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: root.appendingPathComponent("Received", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("Staging", isDirectory: true),
            recordsFileURL: root.appendingPathComponent("records.json")
        )
        for name in ["first.txt", "second.txt"] {
            try Data("data".utf8).write(to: catalog.receivedDirectory.appendingPathComponent(name))
        }
        let suite = "ManualDeletionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(
                identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore()
            ),
            bookmarkStore: USBBookmarkStore(fileURL: root.appendingPathComponent("bookmark.json")),
            registrar: ManualDeletionRegistrar(),
            receiveOnce: { .init(discovered: 0, completed: 0) },
            storedFiles: { try catalog.refresh() },
            deleteStoredFiles: { files in
                await beforeDelete()
                return catalog.delete(files)
            },
            progressUpdates: { progress.updates() },
            defaultDeviceName: "Test iPhone",
            preferences: USBReceiverPreferences(defaults: defaults)
        )
        return (model, catalog)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Expected deletion/receive state was not published")
    }
}

private struct ManualDeletionRegistrar: IPhoneReceiverRegistering {
    func register(uploadCredential: String, deviceName: String) async throws -> IPhoneReceiverRegistration {
        throw URLError(.unsupportedURL)
    }
}

private actor StoredDeletionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var callCount = 0

    func wait() async {
        callCount += 1
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
