import Foundation
import Combine
import XCTest
import ZIPFoundation
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverStoredFileSharingTests: XCTestCase {
    func testZIPDeselectOneFileFromOneThousandEntriesPreservesOtherFiles() async throws {
        try await assertLargeZIPDeselection(count: 1_000)
    }

    func testZIPDeselectOneFileFromTenThousandEntriesPreservesOtherFiles() async throws {
        try await assertLargeZIPDeselection(count: 10_000)
    }

    private func assertLargeZIPDeselection(count: Int) async throws {
        let fixture = try makeFixture(names: [])
        let url = fixture.catalog.receivedDirectory.appendingPathComponent("large.zip")
        do {
            let archive = try Archive(url: url, accessMode: .create)
            for index in 0..<count {
                try archive.addEntry(with: "file-\(index).bin", type: .file, uncompressedSize: Int64(1)) { _, _ in
                    Data([1])
                }
            }
        }
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        await fixture.model.showZIPContents(file)
        XCTAssertEqual(fixture.model.zipEntries.count, count)
        let entry = try XCTUnwrap(fixture.model.zipEntries.first)

        fixture.model.toggleZIPEntry(entry)

        XCTAssertEqual(fixture.model.selectedZIPPaths.count, count - 1)
        XCTAssertFalse(fixture.model.selectedZIPPaths.contains(entry.path))
        fixture.model.toggleZIPEntry(entry)
        XCTAssertEqual(fixture.model.selectedZIPPaths.count, count)
    }

    func testZIPDeselectNestedFileClearsOnlyAncestorDirectoriesAndKeepsSiblingFolder() async throws {
        let fixture = try makeFixture(names: [])
        let source = fixture.catalog.stagingDirectory.appendingPathComponent("tree", isDirectory: true)
        let nested = source.appendingPathComponent("chosen/nested", isDirectory: true)
        let sibling = source.appendingPathComponent("chosen-other", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent("remove.bin"))
        try Data([2]).write(to: nested.appendingPathComponent("keep.bin"))
        try Data([3]).write(to: sibling.appendingPathComponent("sibling.bin"))
        try FileManager.default.zipItem(at: source,
            to: fixture.catalog.receivedDirectory.appendingPathComponent("tree.zip"))
        await fixture.model.refresh()
        await fixture.model.showZIPContents(try XCTUnwrap(fixture.model.storedFiles.first))
        let entry = try XCTUnwrap(fixture.model.zipEntries.first { $0.path.hasSuffix("remove.bin") })
        let original = fixture.model.selectedZIPPaths
        let ancestors = Set(fixture.model.zipEntries.filter {
            $0.isDirectory && entry.path.hasPrefix($0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
        }.map(\.path))

        fixture.model.toggleZIPEntry(entry)

        XCTAssertEqual(fixture.model.selectedZIPPaths, original.subtracting(ancestors).subtracting([entry.path]))
        let folder = try XCTUnwrap(fixture.model.zipEntries.first {
            $0.isDirectory && $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("chosen")
        })
        fixture.model.toggleZIPEntry(folder)
        XCTAssertTrue(fixture.model.selectedZIPPaths.contains(entry.path))
        fixture.model.toggleZIPEntry(folder)
        XCTAssertFalse(fixture.model.selectedZIPPaths.contains(entry.path))
        XCTAssertTrue(fixture.model.selectedZIPPaths.contains { $0.hasSuffix("sibling.bin") })
    }

    func testZIPPickerBlocksNewReceivePolling() async throws {
        let calls = ZIPSelectionCalls()
        let fixture = try makeFixture(names: ["자료.zip"], receiveLocalOnce: {
            await calls.record([:], overwrite: false)
        })
        await fixture.model.refresh()
        fixture.model.setSelectedDestination(.iphoneLocal)
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        await fixture.model.showZIPContents(file)
        let selection = fixture.model.selectedZIPPaths

        await fixture.model.pollOnce()

        let received = await calls.values
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(fixture.model.zipContentsFile?.id, file.id)
        XCTAssertEqual(fixture.model.selectedZIPPaths, selection)
    }

    func testLateReceiveProgressDoesNotDismissZIPSelectionOnExportTap() async throws {
        let calls = ZIPSelectionCalls()
        let progress = USBReceiveProgressStore()
        let fixture = try makeFixture(names: ["자료.zip"], progress: progress,
                                      selectedExportFiles: { _, _, _, overwrite, selections in
            await calls.record(selections, overwrite: overwrite)
            return IPhoneUSBExportSummary(verified: [], failed: [])
        })
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        await fixture.model.showZIPContents(file)
        let selection = fixture.model.selectedZIPPaths
        let receiving = expectation(description: "receive progress published after ZIP opened")
        let observer = fixture.model.$receiveProgress.sink { value in
            if value?.stage == .downloading { receiving.fulfill() }
        }
        defer { observer.cancel() }
        progress.publish(USBReceiveProgress(
            stage: .downloading, destination: .iphoneLocal, deliveryID: UUID(),
            fileName: "incoming.pdf", currentIndex: 1, totalCount: 1, completedCount: 0,
            bytesReceived: 1, totalBytes: 10, startedAt: .now, expiresAt: nil, errorMessage: nil
        ))
        await fulfillment(of: [receiving], timeout: 2)

        await fixture.model.exportSelectedZIPContents()

        let exported = await calls.values
        XCTAssertTrue(exported.isEmpty)
        XCTAssertEqual(fixture.model.zipContentsFile?.id, file.id)
        XCTAssertEqual(fixture.model.selectedZIPPaths, selection)
    }

    func testAlreadyRunningReceivePollCannotOpenZIPPicker() async throws {
        let started = expectation(description: "receive discovery started")
        let gate = ZIPReceiveGate()
        let fixture = try makeFixture(names: ["자료.zip"], receiveLocalOnce: {
            started.fulfill()
            await gate.wait()
        })
        await fixture.model.refresh()
        fixture.model.setSelectedDestination(.iphoneLocal)
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        let poll = Task { await fixture.model.pollOnce() }
        await fulfillment(of: [started], timeout: 2)

        await fixture.model.showZIPContents(file)

        XCTAssertNil(fixture.model.zipContentsFile)
        await gate.release()
        await poll.value
    }
    func testZIPFolderSelectionSurvivesOverwriteConfirmationAndKeepsOriginal() async throws {
        let calls = ZIPSelectionCalls()
        let fixture = try makeFixture(names: [], selectedExportFiles: { files, _, _, overwrite, selections in
            await calls.record(selections, overwrite: overwrite)
            return IPhoneUSBExportSummary(verified: [], failed: overwrite ? [] : [
                IPhoneUSBExportFailure(sourceID: files[0].id, error: .overwriteConfirmationRequired)
            ])
        })
        let source = fixture.catalog.stagingDirectory.appendingPathComponent("payload", isDirectory: true)
        let folder = source.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("one.txt"))
        try Data("skip".utf8).write(to: source.appendingPathComponent("skip.txt"))
        let archive = fixture.catalog.receivedDirectory.appendingPathComponent("selection.zip")
        try FileManager.default.zipItem(at: source, to: archive)
        let original = try Data(contentsOf: archive)
        await fixture.model.refresh()
        let file = try XCTUnwrap(fixture.model.storedFiles.first)
        await fixture.model.showZIPContents(file)
        XCTAssertEqual(fixture.model.selectedZIPPaths, Set(fixture.model.zipEntries.map(\.path)))
        let chosen = try XCTUnwrap(fixture.model.zipEntries.first { $0.isDirectory && $0.path.contains("chosen") })
        let excluded = try XCTUnwrap(fixture.model.zipEntries.first { $0.path.hasSuffix("skip.txt") })
        fixture.model.toggleZIPEntry(excluded)
        let selection = fixture.model.selectedZIPPaths
        XCTAssertTrue(selection.contains(chosen.path))
        XCTAssertFalse(selection.contains(excluded.path))

        await fixture.model.exportSelectedZIPContents()
        XCTAssertTrue(fixture.model.needsStoredOverwriteConfirmation)
        await fixture.model.confirmStoredFileOverwrite()

        let recorded = await calls.values
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.map(\.selections), [[file.id: selection], [file.id: selection]])
        XCTAssertEqual(recorded.map(\.overwrite), [false, true])
        XCTAssertFalse(fixture.model.needsDeletionDecision)
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }
    func testSelectedFilesShareOriginalURLsAndCancelKeepsSelection() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let files = fixture.model.storedFiles
        for file in files { fixture.model.toggleStoredFileSelection(file.id) }
        let bytes = try files.map { try Data(contentsOf: $0.url) }

        fixture.model.shareSelectedStoredFiles()

        XCTAssertEqual(fixture.model.sharingSelection?.files.map(\.url), files.map(\.url))
        fixture.model.finishSharingStoredFile(error: nil)
        XCTAssertNil(fixture.model.sharingSelection)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, Set(files.map(\.id)))
        XCTAssertEqual(try files.map { try Data(contentsOf: $0.url) }, bytes)
    }

    func testSelectedSharingStopsWhenAnyOriginalIsMissing() async throws {
        let fixture = try makeFixture()
        await fixture.model.refresh()
        let files = fixture.model.storedFiles
        for file in files { fixture.model.toggleStoredFileSelection(file.id) }
        try FileManager.default.removeItem(at: files[1].url)

        fixture.model.shareSelectedStoredFiles()

        XCTAssertNil(fixture.model.sharingSelection)
        XCTAssertNotNil(fixture.model.storedFileShareError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].url.path))
    }

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
        await fixture.model.refresh()

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
        progress: USBReceiveProgressStore = USBReceiveProgressStore(),
        selectedExportFiles: USBReceiverViewModel.SelectedExportFiles? = nil,
        receiveLocalOnce: @escaping USBReceiverViewModel.ReceiveLocalOnce = {}
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
        let bookmarkStore = USBBookmarkStore(fileURL: root.appendingPathComponent("bookmark.json"), codec: SharingBookmarkCodec())
        try bookmarkStore.save(folderURL: root, volumeID: "test", displayName: "USB")
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore()),
            bookmarkStore: bookmarkStore,
            registrar: StoredFileSharingRegistrar(),
            receiveOnce: { .init(discovered: 0, completed: 0) },
            receiveLocalOnce: receiveLocalOnce,
            storedFiles: { try catalog.refresh() },
            previewStoredFile: { try catalog.previewURL(for: $0) },
            canPreviewFile: { _ in true },
            deleteStoredFiles: { files, callback in catalog.delete(files, progress: callback) },
            progressUpdates: { progress.updates() },
            defaultDeviceName: "Test iPhone",
            preferences: USBReceiverPreferences(defaults: defaults),
            selectedExportFiles: selectedExportFiles
        )
        return (model, catalog)
    }
}

private actor ZIPReceiveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ZIPSelectionCalls {
    struct Call {
        let selections: [String: Set<String>]
        let overwrite: Bool
    }
    private(set) var values: [Call] = []
    func record(_ selections: [String: Set<String>], overwrite: Bool) {
        values.append(Call(selections: selections, overwrite: overwrite))
    }
}

private struct SharingBookmarkCodec: USBBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        USBBookmarkResolution(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), isStale: false)
    }
}

private struct StoredFileSharingRegistrar: IPhoneReceiverRegistering {
    func register(uploadCredential: String, deviceName: String) async throws -> IPhoneReceiverRegistration {
        throw URLError(.unsupportedURL)
    }
}
