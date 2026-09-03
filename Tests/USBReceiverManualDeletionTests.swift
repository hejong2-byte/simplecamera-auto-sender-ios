import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverManualDeletionTests: XCTestCase {
    func testOpeningStoredFilePreservesSelectionAndReceiveAndUSBState() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)
        let status = fixture.model.receiveStatus

        fixture.model.openStoredFile(file)

        XCTAssertEqual(fixture.model.previewFile, file)
        XCTAssertNil(fixture.model.storedFilePreviewError)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, [file.id])
        XCTAssertTrue(fixture.model.canDeleteStoredFiles)
        XCTAssertEqual(fixture.model.receiveStatus, status)
        XCTAssertNil(fixture.model.usbExportProgress)
        XCTAssertEqual(try fixture.catalog.refresh().count, 2)
        fixture.model.previewFile = nil
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, [file.id])
    }

    func testMissingPreviewRefreshesCatalogAndDoesNotBecomeReceiveFailure() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        let status = fixture.model.receiveStatus
        try FileManager.default.removeItem(at: file.url)

        fixture.model.openStoredFile(file)

        XCTAssertNil(fixture.model.previewFile)
        XCTAssertNotNil(fixture.model.storedFilePreviewError)
        XCTAssertEqual(fixture.model.storedFiles.count, 1)
        XCTAssertEqual(fixture.model.receiveStatus, status)
        XCTAssertNil(fixture.model.lastError)
    }

    func testUnsupportedPreviewIsReportedAndRetainsOriginalAndSelection() async throws {
        let fixture = try makeFixture(canPreview: { _ in false })
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)
        fixture.model.openStoredFile(file)

        XCTAssertNil(fixture.model.previewFile)
        XCTAssertTrue(fixture.model.storedFilePreviewError?.contains("지원하지") == true)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, [file.id])
        XCTAssertEqual(try fixture.catalog.refresh().count, 2)
    }

    func testSelectionControlsDeletionButtonDuringRepeatedIdlePolls() async throws {
        for destination in IPhoneReceiveDestination.allCases {
            let gate = StoredDeletionGate()
            let fixture = try makeFixture(beforePoll: { await gate.wait() })
            await fixture.model.refresh()
            fixture.model.setSelectedDestination(destination)
            let file = try XCTUnwrap(fixture.model.storedFiles.first)
            XCTAssertFalse(fixture.model.canDeleteStoredFiles)
            fixture.model.toggleStoredFileSelection(file.id)

            for _ in 0..<3 {
                await gate.reset()
                let poll = Task { await fixture.model.pollOnce() }
                await waitUntil { fixture.model.isPerformingReceive }

                XCTAssertTrue(fixture.model.canDeleteStoredFiles,
                              "An idle server check must not disable the selected-file button")
                fixture.model.toggleStoredFileSelection(file.id)
                XCTAssertFalse(fixture.model.canDeleteStoredFiles)
                fixture.model.toggleStoredFileSelection(file.id)
                XCTAssertTrue(fixture.model.canDeleteStoredFiles)

                await gate.release()
                await poll.value
                XCTAssertTrue(fixture.model.canDeleteStoredFiles)
            }
            XCTAssertEqual(try fixture.catalog.refresh().count, 2)
        }
    }

    func testConfirmedDeletionSucceedsWhileIdleServerCheckIsWaiting() async throws {
        for destination in IPhoneReceiveDestination.allCases {
            let gate = StoredDeletionGate()
            let fixture = try makeFixture(beforePoll: { await gate.wait() })
            await fixture.model.refresh()
            fixture.model.setSelectedDestination(destination)
            let file = try XCTUnwrap(fixture.model.storedFiles.first)
            fixture.model.toggleStoredFileSelection(file.id)
            let poll = Task { await fixture.model.pollOnce() }
            await waitUntil { fixture.model.isPerformingReceive }

            fixture.model.requestStoredFileDeletion()
            XCTAssertTrue(fixture.model.needsStoredFileDeletionConfirmation)
            await fixture.model.deleteConfirmedStoredFiles()

            XCTAssertEqual(try fixture.catalog.refresh().count, 1)
            XCTAssertEqual(fixture.model.storedFileDeletionMessage, "iPhone 파일 1개 삭제 완료")
            XCTAssertNil(fixture.model.storedFileDeletionError)
            XCTAssertFalse(fixture.model.canDeleteStoredFiles)
            await gate.release()
            await poll.value
        }
    }

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

        XCTAssertTrue(fixture.model.canDeleteStoredFiles,
                      "Selection keeps the button enabled; an actual transfer is explained on tap")
        fixture.model.requestStoredFileDeletion()

        XCTAssertFalse(fixture.model.needsStoredFileDeletionConfirmation)
        XCTAssertTrue(fixture.model.storedFileDeletionError?.contains("전송 중") == true)
        XCTAssertEqual(try fixture.catalog.refresh().count, 2)
    }

    func testReceiveStartingAfterConfirmationStillProtectsFiles() async throws {
        let progress = USBReceiveProgressStore()
        let fixture = try makeFixture(progress: progress)
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)
        fixture.model.requestStoredFileDeletion()
        XCTAssertTrue(fixture.model.needsStoredFileDeletionConfirmation)
        progress.publish(USBReceiveProgress(
            stage: .downloading, destination: .iphoneLocal, deliveryID: UUID(),
            fileName: "incoming.zip", currentIndex: 1, totalCount: 1, completedCount: 0,
            bytesReceived: 1, totalBytes: 10, startedAt: .now,
            expiresAt: nil, errorMessage: nil
        ))
        await waitUntil { fixture.model.isReceivingFile }

        await fixture.model.deleteConfirmedStoredFiles()

        XCTAssertEqual(try fixture.catalog.refresh().count, 2)
        XCTAssertTrue(fixture.model.canDeleteStoredFiles)
        XCTAssertFalse(fixture.model.needsStoredFileDeletionConfirmation)
        XCTAssertTrue(fixture.model.storedFileDeletionError?.contains("전송 중") == true)
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

        XCTAssertFalse(fixture.model.canDeleteStoredFiles)
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
        beforePoll: @escaping @Sendable () async -> Void = {},
        beforeDelete: @escaping @Sendable () async -> Void = {},
        canPreview: @escaping (URL) -> Bool = { _ in true }
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
            receiveOnce: {
                await beforePoll()
                return .init(discovered: 0, completed: 0)
            },
            receiveLocalOnce: { await beforePoll() },
            storedFiles: { try catalog.refresh() },
            previewStoredFile: { try catalog.previewURL(for: $0) },
            canPreviewFile: canPreview,
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

    func reset() {
        precondition(continuation == nil)
        released = false
    }
}
