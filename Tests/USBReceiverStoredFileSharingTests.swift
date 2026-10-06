import Foundation
import XCTest
import ZIPFoundation
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverStoredFileSharingTests: XCTestCase {
    func testOnlyPhotosPDFAndZIPOfferDirectSharing() async throws {
        let fixture = try makeFixture(names: ["photo.jpg", "photo.PNG", "photo.heic", "document.PDF", "archive.zip", "자료.ZIP", "notes.txt", "movie.mp4", "archive.zip.txt"])
        await fixture.model.refresh()
        for file in fixture.model.storedFiles {
            let supported = ["jpg", "png", "heic", "pdf", "zip"].contains(file.url.pathExtension.lowercased())
            XCTAssertEqual(file.supportsDirectSharing, supported, file.name)
            XCTAssertEqual(fixture.model.canShareStoredFile(file), supported, file.name)
        }
    }

    func testZIPSharingAndCancelKeepsOriginalArchiveWithoutExtraction() async throws {
        let fixture = try makeFixture(names: ["받은 자료.ZIP"])
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        let bytes = try Data(contentsOf: file.url)
        fixture.model.toggleStoredFileSelection(file.id)

        fixture.model.shareStoredFile(file)

        XCTAssertEqual(fixture.model.sharingFile?.url, file.url)
        XCTAssertEqual(fixture.model.sharingFile?.name, "받은 자료.ZIP")
        XCTAssertNil(fixture.model.storedFileShareError)
        fixture.model.finishSharingStoredFile(error: nil)

        XCTAssertNil(fixture.model.sharingFile)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, [file.id])
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.catalog.receivedDirectory.path), ["받은 자료.ZIP"])
        XCTAssertEqual(try fixture.catalog.refresh(), [file])
    }

    func testSharingOriginalAndCancelPreservesBytesSelectionAndReceiverState() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        let bytes = try Data(contentsOf: file.url)
        let status = fixture.model.receiveStatus
        fixture.model.toggleStoredFileSelection(file.id)

        fixture.model.shareStoredFile(file)

        XCTAssertEqual(fixture.model.sharingFile, file)
        XCTAssertEqual(fixture.model.sharingFile?.url, file.url)
        XCTAssertNil(fixture.model.storedFileShareError)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, [file.id])
        XCTAssertEqual(fixture.model.receiveStatus, status)
        XCTAssertNil(fixture.model.usbExportProgress)
        XCTAssertFalse(fixture.model.canDeleteStoredFiles)
        fixture.model.requestStoredFileDeletion()
        XCTAssertFalse(fixture.model.needsStoredFileDeletionConfirmation)

        fixture.model.finishSharingStoredFile(error: nil)

        XCTAssertNil(fixture.model.sharingFile)
        XCTAssertNil(fixture.model.storedFileShareError)
        XCTAssertTrue(fixture.model.canDeleteStoredFiles)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, [file.id])
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(try fixture.catalog.refresh().count, 2)
    }

    func testMissingFileRefreshesListWithoutCreatingAReceiveFailure() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        let status = fixture.model.receiveStatus
        fixture.model.toggleStoredFileSelection(file.id)
        try FileManager.default.removeItem(at: file.url)

        fixture.model.shareStoredFile(file)

        XCTAssertNil(fixture.model.sharingFile)
        XCTAssertNotNil(fixture.model.storedFileShareError)
        XCTAssertEqual(fixture.model.storedFiles.count, 1)
        XCTAssertTrue(fixture.model.selectedStoredFileIDs.isEmpty)
        XCTAssertEqual(fixture.model.receiveStatus, status)
        XCTAssertNil(fixture.model.lastError)
    }

    func testChangedOriginalIsNotSharedUsingAnOldSnapshot() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)
        let replacement = Data("changed original contents".utf8)
        try replacement.write(to: file.url)

        fixture.model.shareStoredFile(file)

        XCTAssertNil(fixture.model.sharingFile)
        XCTAssertTrue(fixture.model.storedFileShareError?.contains("변경") == true)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, [file.id])
        XCTAssertEqual(try Data(contentsOf: file.url), replacement)
    }

    func testFileOutsideReceivedDirectoryIsNotShared() async throws {
        let fixture = try makeFixture()
        let url = fixture.catalog.stagingDirectory.appendingPathComponent("still-downloading.pdf")
        try Data("incomplete download".utf8).write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let file = IPhoneStoredFile(id: url.path, url: url, name: url.lastPathComponent,
                                   size: (attributes[.size] as! NSNumber).int64Value,
                                   modifiedAt: attributes[.modificationDate] as! Date, receivedRecord: nil)

        fixture.model.shareStoredFile(file)

        XCTAssertNil(fixture.model.sharingFile)
        XCTAssertNotNil(fixture.model.storedFileShareError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnsupportedFileDoesNotOpenShareSheet() async throws {
        let fixture = try makeFixture(names: ["notes.txt"])
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)

        fixture.model.shareStoredFile(file)

        XCTAssertNil(fixture.model.sharingFile)
        XCTAssertEqual(try fixture.catalog.refresh().count, 1)
    }

    func testSecondShareAndPreviewCannotReplaceAnActiveShare() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let first = fixture.model.storedFiles[0]
        let second = fixture.model.storedFiles[1]
        fixture.model.shareStoredFile(first)

        fixture.model.shareStoredFile(second)
        fixture.model.openStoredFile(second)

        XCTAssertEqual(fixture.model.sharingFile, first)
        XCTAssertNil(fixture.model.previewFile)
        fixture.model.finishSharingStoredFile(error: nil)
        fixture.model.shareStoredFile(second)
        XCTAssertEqual(fixture.model.sharingFile, second)
    }

    func testPendingDeletionAndPreviewAndFolderPickerBlockSharing() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        fixture.model.toggleStoredFileSelection(file.id)
        fixture.model.requestStoredFileDeletion()
        fixture.model.shareStoredFile(file)
        XCTAssertNil(fixture.model.sharingFile)
        fixture.model.cancelStoredFileDeletion()

        fixture.model.openStoredFile(file)
        fixture.model.shareStoredFile(file)
        XCTAssertNil(fixture.model.sharingFile)
        fixture.model.previewFile = nil

        fixture.model.isChoosingUSBFolder = true
        fixture.model.shareStoredFile(file)
        XCTAssertNil(fixture.model.sharingFile)
        fixture.model.isChoosingUSBFolder = false
        XCTAssertTrue(fixture.model.canShareStoredFile(file))
    }

    func testActiveDownloadBlocksSharing() async throws {
        let progress = USBReceiveProgressStore()
        let fixture = try makeFixture(progress: progress)
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        progress.publish(USBReceiveProgress(
            stage: .downloading, destination: .iphoneLocal, deliveryID: UUID(),
            fileName: file.name, currentIndex: 1, totalCount: 1, completedCount: 0,
            bytesReceived: 1, totalBytes: 10, startedAt: .now, expiresAt: nil, errorMessage: nil
        ))
        for _ in 0..<500 {
            if fixture.model.isReceivingFile { break }
            await Task.yield()
        }
        XCTAssertTrue(fixture.model.isReceivingFile)

        fixture.model.shareStoredFile(file)

        XCTAssertNil(fixture.model.sharingFile)
        XCTAssertFalse(fixture.model.canShareStoredFile(file))
    }

    func testShareExtensionFailureKeepsOriginalAndDoesNotBecomeReceiveError() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        let status = fixture.model.receiveStatus
        fixture.model.shareStoredFile(file)

        fixture.model.finishSharingStoredFile(error: CocoaError(.fileReadUnknown))

        XCTAssertNil(fixture.model.sharingFile)
        XCTAssertNotNil(fixture.model.storedFileShareError)
        XCTAssertEqual(fixture.model.receiveStatus, status)
        XCTAssertNil(fixture.model.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        fixture.model.storedFileShareError = nil
        XCTAssertTrue(fixture.model.canShareStoredFile(file))
    }

    private func makeFixture(
        names: [String] = ["받은 문서.pdf", "받은 사진.png"],
        progress: USBReceiveProgressStore = USBReceiveProgressStore()
    ) throws -> (model: USBReceiverViewModel, catalog: IPhoneReceivedFileCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: root.appendingPathComponent("Received", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("Staging", isDirectory: true),
            recordsFileURL: root.appendingPathComponent("records.json")
        )
        for name in names {
            let url = catalog.receivedDirectory.appendingPathComponent(name)
            if url.pathExtension.lowercased() == "zip" {
                let source = catalog.stagingDirectory.appendingPathComponent("문서.txt")
                try Data("original file bytes".utf8).write(to: source)
                try FileManager.default.zipItem(at: source, to: url)
            } else {
                try Data("original file bytes".utf8).write(to: url)
            }
        }
        let suite = "StoredFileSharingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore()),
            bookmarkStore: USBBookmarkStore(fileURL: root.appendingPathComponent("bookmark.json")),
            registrar: StoredFileSharingRegistrar(),
            receiveOnce: { .init(discovered: 0, completed: 0) },
            storedFiles: { try catalog.refresh() },
            previewStoredFile: { try catalog.previewURL(for: $0) },
            canPreviewFile: { _ in true },
            deleteStoredFiles: { files, callback in catalog.delete(files, progress: callback) },
            progressUpdates: { progress.updates() },
            defaultDeviceName: "Test iPhone",
            preferences: USBReceiverPreferences(defaults: defaults)
        )
        return (model, catalog)
    }
}

private struct StoredFileSharingRegistrar: IPhoneReceiverRegistering {
    func register(uploadCredential: String, deviceName: String) async throws -> IPhoneReceiverRegistration {
        throw URLError(.unsupportedURL)
    }
}
