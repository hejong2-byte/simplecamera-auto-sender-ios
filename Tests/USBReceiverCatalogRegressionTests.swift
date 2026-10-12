import Foundation
import Combine
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverCatalogRegressionTests: XCTestCase {
    func testConcurrentCatalogRefreshesCoalesceAndNeverPublishSupersededSnapshot() async throws {
        let root = try directory()
        let old = IPhoneStoredFile(id: "old", url: root.appendingPathComponent("old.pdf"), name: "old.pdf",
                                   size: 1, modifiedAt: Date(), receivedRecord: nil)
        let newest = IPhoneStoredFile(id: "new", url: root.appendingPathComponent("new.pdf"), name: "new.pdf",
                                      size: 1, modifiedAt: Date(), receivedRecord: nil)
        let started = expectation(description: "first catalog read started")
        let release = DispatchSemaphore(value: 0)
        let counter = CatalogReadCounter()
        let model = try makeModel(root: root, storedFiles: {
            if counter.next() == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return [old]
            }
            return [newest]
        })
        var publishedIDs: [[String]] = []
        let observation = model.$storedFiles.dropFirst().sink { publishedIDs.append($0.map(\.id)) }
        defer { observation.cancel(); release.signal() }
        let first = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let queued = expectation(description: "all refresh requests queued")
        queued.expectedFulfillmentCount = 12
        let refreshes = (0..<12).map { _ in Task {
            queued.fulfill()
            await model.refresh()
        } }
        await fulfillment(of: [queued], timeout: 2)
        release.signal()
        await first.value
        for refresh in refreshes { await refresh.value }

        XCTAssertEqual(model.storedFiles.map(\.id), ["new"])
        XCTAssertEqual(publishedIDs, [["new"]])
        XCTAssertEqual(counter.count, 2)
    }
    func testSelectingAnotherUSBRootClearsPreviousFolderAndSelection() async throws {
        let first = try directory()
        let nested = first.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: nested.appendingPathComponent("same.bin"))
        let second = try directory()
        try Data("new".utf8).write(to: second.appendingPathComponent("same.bin"))
        let model = try makeModel(root: first)
        await model.refreshStorageFiles()
        await model.openStorageDirectory(try XCTUnwrap(model.storageEntries.first))
        model.toggleStorageEntrySelection("old/same.bin")

        await model.selectDestination(second)

        XCTAssertEqual(model.storageRelativePath, "")
        XCTAssertTrue(model.selectedStorageFilePaths.isEmpty)
        XCTAssertEqual(model.storageEntries.map(\.name), ["same.bin"])
        XCTAssertNil(model.storageExplorerError)
    }

    func testSelectingAnotherUSBRootDoesNotSelectSameNamedFile() async throws {
        let first = try directory()
        let second = try directory()
        for root in [first, second] {
            try Data(root.lastPathComponent.utf8).write(to: root.appendingPathComponent("same.bin"))
        }
        let model = try makeModel(root: first)
        await model.refreshStorageFiles()
        model.toggleStorageEntrySelection("same.bin")

        await model.selectDestination(second)

        XCTAssertTrue(model.selectedStorageFilePaths.isEmpty)
        XCTAssertEqual(model.storageEntries.map(\.name), ["same.bin"])
    }

    func testOldUSBListingCannotReplaceNewRootSnapshot() async throws {
        let first = try directory()
        let second = try directory()
        try Data("old".utf8).write(to: first.appendingPathComponent("old.bin"))
        try Data("new".utf8).write(to: second.appendingPathComponent("new.bin"))
        let started = expectation(description: "old root listing started")
        let release = DispatchSemaphore(value: 0)
        let explorer = USBStorageFileExplorer(startAccessing: { url in
            if url == first {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return true
        }, stopAccessing: { _ in })
        let model = try makeModel(root: first, explorer: explorer)
        let oldRefresh = Task { await model.refreshStorageFiles() }
        await fulfillment(of: [started], timeout: 2)

        await model.selectDestination(second)
        release.signal()
        await oldRefresh.value

        XCTAssertEqual(model.storageEntries.map(\.name), ["new.bin"])
        XCTAssertNil(model.storageExplorerError)
    }

    func testReceivedCatalogRefreshKeepsMainActorAvailable() async throws {
        let model = try makeModel(root: directory(), storedFiles: {
            XCTAssertFalse(Thread.isMainThread, "Disk catalog reads must run off the UI thread")
            let heartbeat = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { heartbeat.signal() }
            XCTAssertEqual(heartbeat.wait(timeout: .now() + 2), .success)
            return []
        })

        await model.refresh()

        XCTAssertTrue(model.storedFiles.isEmpty)
    }

    private func makeModel(
        root: URL,
        explorer: USBStorageFileExplorer = USBStorageFileExplorer(
            startAccessing: { _ in true }, stopAccessing: { _ in }
        ),
        storedFiles: @escaping USBReceiverViewModel.StoredFilesProvider = { [] }
    ) throws -> USBReceiverViewModel {
        let store = USBBookmarkStore(fileURL: try directory().appendingPathComponent("bookmark.json"),
                                     codec: RegressionBookmarkCodec())
        try store.save(folderURL: root, volumeID: "test", displayName: "USB")
        let suite = "USBReceiverCatalogRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(),
                                                               secretStore: InMemoryCredentialStore()),
            bookmarkStore: store, registrar: RegressionRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            storedFiles: storedFiles,
            progressUpdates: { AsyncStream { $0.finish() } }, defaultDeviceName: "iPhone",
            preferences: USBReceiverPreferences(defaults: defaults), storageExplorer: explorer
        )
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                               isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class CatalogReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private struct RegressionBookmarkCodec: USBBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        USBBookmarkResolution(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
                              isStale: false)
    }
}

private actor RegressionRegistrar: IPhoneReceiverRegistering {
    func register(uploadCredential: String, deviceName: String) async throws -> IPhoneReceiverRegistration {
        IPhoneReceiverRegistration(receiverID: UUID(), code: "123456", receiveSecret: "synthetic",
                                   deviceName: deviceName)
    }
}
