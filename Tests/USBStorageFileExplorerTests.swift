import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBStorageFileExplorerTests: XCTestCase {
    func testListsDirectoriesBeforeFilesAndIncludesHiddenRegularFiles() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("MAP", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("z".utf8).write(to: root.appendingPathComponent("z.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".SimpleCameraReceiver", isDirectory: true),
            withIntermediateDirectories: true
        )

        let explorer = makeExplorer()
        let entries = try explorer.list(
            destination: destination(root),
            relativePath: ""
        )

        XCTAssertEqual(entries.map(\.name), ["MAP", ".hidden", "z.txt"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file, .file])
        XCTAssertEqual(entries[1].size, 6)
    }

    func testListsNestedDirectoryWithRootRelativePaths() throws {
        let root = temporaryDirectory()
        let nested = root.appendingPathComponent("MAP", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("route".utf8).write(to: nested.appendingPathComponent("route.bin"))

        let entries = try makeExplorer().list(
            destination: destination(root),
            relativePath: "MAP"
        )

        XCTAssertEqual(entries.map(\.relativePath), ["MAP/route.bin"])
        XCTAssertEqual(entries.map(\.kind), [.file])
    }

    func testRejectsTraversalOutsideSelectedRoot() throws {
        let root = temporaryDirectory()

        XCTAssertThrowsError(
            try makeExplorer().list(
                destination: destination(root),
                relativePath: "../outside"
            )
        ) { error in
            XCTAssertEqual(error as? USBStorageFileExplorerError, .invalidPath)
        }
    }

    func testSymbolicLinksAreNotListedOrTransferable() async throws {
        let parent = temporaryDirectory()
        let root = parent.appendingPathComponent("USB", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.bin"),
            withDestinationURL: outside
        )

        let explorer = makeExplorer()
        XCTAssertTrue(try explorer.list(destination: destination(root), relativePath: "").isEmpty)
        do {
            try await explorer.withFiles(
                destination: destination(root),
                relativePaths: ["linked.bin"]
            ) { _ in }
            XCTFail("A symbolic link must never become a transfer source")
        } catch {
            XCTAssertEqual(error as? USBStorageFileExplorerError, .invalidFile)
        }
    }

    func testKeepsRootScopeOpenUntilSelectedFilesFinishPreparing() async throws {
        let root = temporaryDirectory()
        try Data("payload".utf8).write(to: root.appendingPathComponent("file.bin"))
        let scope = StorageScopeLog()
        let explorer = USBStorageFileExplorer(
            startAccessing: { scope.start($0) },
            stopAccessing: { scope.stop($0) }
        )

        try await explorer.withFiles(
            destination: destination(root),
            relativePaths: ["file.bin"]
        ) { urls in
            XCTAssertTrue(scope.isActive)
            XCTAssertEqual(urls.map(\.lastPathComponent), ["file.bin"])
            XCTAssertEqual(try Data(contentsOf: urls[0]), Data("payload".utf8))
        }

        XCTAssertFalse(scope.isActive)
        XCTAssertEqual(scope.startCount, 1)
        XCTAssertEqual(scope.stopCount, 1)
    }

    func testStaleDestinationIsRejectedBeforeScopeAccess() throws {
        let root = temporaryDirectory()
        let scope = StorageScopeLog()
        let explorer = USBStorageFileExplorer(
            startAccessing: { scope.start($0) },
            stopAccessing: { scope.stop($0) }
        )
        let stale = USBBookmarkDestination(
            url: root,
            volumeID: "volume-1",
            displayName: "USB",
            isStale: true
        )

        XCTAssertThrowsError(try explorer.list(destination: stale, relativePath: "")) { error in
            XCTAssertEqual(error as? USBStorageFileExplorerError, .permissionExpired)
        }
        XCTAssertEqual(scope.startCount, 0)
    }

    private func makeExplorer() -> USBStorageFileExplorer {
        USBStorageFileExplorer(startAccessing: { _ in true }, stopAccessing: { _ in })
    }

    private func destination(_ url: URL) -> USBBookmarkDestination {
        USBBookmarkDestination(
            url: url,
            volumeID: "volume-1",
            displayName: "USB",
            isStale: false
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class StorageScopeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var starts = 0
    private var stops = 0

    var isActive: Bool { lock.withLock { active > 0 } }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func start(_ url: URL) -> Bool {
        lock.withLock {
            starts += 1
            active += 1
        }
        return true
    }

    func stop(_ url: URL) {
        lock.withLock {
            stops += 1
            active -= 1
        }
    }
}
