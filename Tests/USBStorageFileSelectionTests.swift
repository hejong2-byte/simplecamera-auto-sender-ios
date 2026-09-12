import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBStorageFileSelectionTests: XCTestCase {
    func testRefreshesSelectedStorageRootAndNavigatesFolders() async throws {
        let root = temporaryDirectory()
        let nested = root.appendingPathComponent("MAP", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("route".utf8).write(to: nested.appendingPathComponent("route.bin"))
        let model = try makeModel(root: root)

        await model.refreshStorageFiles()
        XCTAssertEqual(model.storageEntries.map(\.name), ["MAP"])

        await model.openStorageDirectory(model.storageEntries[0])
        XCTAssertEqual(model.storageRelativePath, "MAP")
        XCTAssertEqual(model.storageEntries.map(\.name), ["route.bin"])

        await model.openParentStorageDirectory()
        XCTAssertEqual(model.storageRelativePath, "")
        XCTAssertEqual(model.storageEntries.map(\.name), ["MAP"])
    }

    func testSelectsMultipleFilesAndReportsCountAndBytes() async throws {
        let root = temporaryDirectory()
        try Data(repeating: 1, count: 3).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 7).write(to: root.appendingPathComponent("b.bin"))
        let model = try makeModel(root: root)

        await model.refreshStorageFiles()
        for entry in model.storageEntries {
            model.toggleStorageFileSelection(entry.relativePath)
        }

        XCTAssertEqual(model.selectedStorageFileCount, 2)
        XCTAssertEqual(model.selectedStorageFileBytes, 10)
        XCTAssertTrue(model.hasStorageFileSelection)
    }

    func testRefreshRemovesSelectionForFileDeletedOutsideApp() async throws {
        let root = temporaryDirectory()
        let file = root.appendingPathComponent("gone.bin")
        try Data("gone".utf8).write(to: file)
        let model = try makeModel(root: root)

        await model.refreshStorageFiles()
        model.toggleStorageFileSelection("gone.bin")
        try FileManager.default.removeItem(at: file)
        await model.refreshStorageFiles()

        XCTAssertFalse(model.hasStorageFileSelection)
        XCTAssertTrue(model.storageEntries.isEmpty)
    }

    func testSendsSelectedFilesToChosenReceiverWhileScopeIsOpen() async throws {
        let root = temporaryDirectory()
        try Data("one".utf8).write(to: root.appendingPathComponent("one.bin"))
        try Data("two".utf8).write(to: root.appendingPathComponent("two.bin"))
        let scope = SelectionScopeLog()
        let explorer = USBStorageFileExplorer(
            startAccessing: { scope.start($0) },
            stopAccessing: { scope.stop($0) }
        )
        let model = try makeModel(root: root, explorer: explorer)
        let sendLog = StorageSendLog(scope: scope)

        await model.refreshStorageFiles()
        model.storageEntries.forEach { model.toggleStorageFileSelection($0.relativePath) }
        await model.sendSelectedStorageFiles(to: "709592") { urls, code in
            await sendLog.record(urls: urls, code: code)
        }

        let result = await sendLog.result()
        XCTAssertEqual(result.code, "709592")
        XCTAssertEqual(result.names, ["one.bin", "two.bin"])
        XCTAssertTrue(result.scopeWasOpen)
        XCTAssertFalse(model.hasStorageFileSelection)
        XCTAssertNil(model.storageExplorerError)
    }

    func testStaleBookmarkShowsPermissionErrorWithoutSending() async throws {
        let root = temporaryDirectory()
        try Data("file".utf8).write(to: root.appendingPathComponent("file.bin"))
        let model = try makeModel(root: root, isStale: true)
        let sendLog = StorageSendLog(scope: SelectionScopeLog())

        await model.refreshStorageFiles()
        await model.sendSelectedStorageFiles(to: "709592") { urls, code in
            await sendLog.record(urls: urls, code: code)
        }

        XCTAssertEqual(model.storageExplorerError, "저장장치 폴더 권한이 만료되었습니다. 다시 선택해 주세요.")
        let callCount = await sendLog.callCount()
        XCTAssertEqual(callCount, 0)
    }

    private func makeModel(
        root: URL,
        isStale: Bool = false,
        explorer: USBStorageFileExplorer = USBStorageFileExplorer(
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
    ) throws -> USBReceiverViewModel {
        let bookmarkFile = temporaryDirectory().appendingPathComponent("destination.json")
        let bookmarkStore = USBBookmarkStore(
            fileURL: bookmarkFile,
            codec: SelectionBookmarkCodec(url: root, isStale: isStale)
        )
        try bookmarkStore.save(folderURL: root, volumeID: "volume", displayName: "USB")
        return USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(
                identityStore: InMemoryCredentialStore(),
                secretStore: InMemoryCredentialStore()
            ),
            bookmarkStore: bookmarkStore,
            registrar: SelectionReceiverRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: isolatedPreferences(),
            storageExplorer: explorer
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func isolatedPreferences() -> USBReceiverPreferences {
        let suite = "USBStorageFileSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return USBReceiverPreferences(defaults: defaults)
    }
}

private struct SelectionBookmarkCodec: USBBookmarkCoding {
    let url: URL
    let isStale: Bool

    func makeBookmark(for url: URL) throws -> Data { Data("bookmark".utf8) }
    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        USBBookmarkResolution(url: url, isStale: isStale)
    }
}

private actor SelectionReceiverRegistrar: IPhoneReceiverRegistering {
    func register(uploadCredential: String, deviceName: String) async throws -> IPhoneReceiverRegistration {
        IPhoneReceiverRegistration(
            receiverID: UUID(),
            code: "123456",
            receiveSecret: "secret",
            deviceName: deviceName
        )
    }
}

private final class SelectionScopeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0

    var isActive: Bool { lock.withLock { active > 0 } }

    func start(_ url: URL) -> Bool {
        lock.withLock { active += 1 }
        return true
    }

    func stop(_ url: URL) {
        lock.withLock { active -= 1 }
    }
}

private actor StorageSendLog {
    private let scope: SelectionScopeLog
    private var calls: [(names: [String], code: String, scopeWasOpen: Bool)] = []

    init(scope: SelectionScopeLog) {
        self.scope = scope
    }

    func record(urls: [URL], code: String) {
        calls.append((urls.map(\.lastPathComponent), code, scope.isActive))
    }

    func result() -> (names: [String], code: String, scopeWasOpen: Bool) {
        calls[0]
    }

    func callCount() -> Int { calls.count }
}
