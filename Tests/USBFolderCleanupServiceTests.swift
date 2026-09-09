import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBFolderCleanupServiceTests: XCTestCase {
    func testDelayedProviderRemovalIsRecheckedBeforeReporting65Remaining() async throws {
        let root = temporaryDirectory()
        for index in 0..<65 {
            try Data([1]).write(to: root.appendingPathComponent("file-\(index).bin"))
        }
        let service = USBFolderCleanupService(fileManager: DelayedRemovalFileManager(),
            volumeIdentity: { _ in "volume-1" }, startAccessing: { _ in true }, stopAccessing: { _ in })
        let target = destination(root, volumeID: "volume-1")
        let before = try await service.inspect(target)
        let result = try await service.deleteAllContents(of: target, matching: before)
        XCTAssertEqual(result.remainingItemCount, 0, "Do not report the provider's first stale listing as final")
        XCTAssertEqual(result.deletedItemCount, 65)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testUSBDeletionReportsProgressForTopLevelItems() async throws {
        let root = temporaryDirectory()
        for name in ["one.txt", "two.txt"] {
            try Data("test".utf8).write(to: root.appendingPathComponent(name))
        }
        let service = makeService(volumeID: "volume-1")
        let target = destination(root, volumeID: "volume-1")
        let summary = try await service.inspect(target)
        let log = DeletionProgressLog()
        _ = try await service.deleteAllContents(of: target, matching: summary, progress: log.append)
        XCTAssertEqual(log.values.last?.processedCount, 2)
        XCTAssertEqual(log.values.last?.failedCount, 0)
        XCTAssertTrue(log.values.contains { $0.percent == 50 })
    }

    func testProviderErrorAfterActualRemovalDoesNotReportPhantomFailure() async throws {
        let root = temporaryDirectory()
        try Data("test".utf8).write(to: root.appendingPathComponent("removed.txt"))
        let service = USBFolderCleanupService(
            fileManager: RemovedThenErrorFileManager(),
            volumeIdentity: { _ in "volume-1" },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
        let target = destination(root, volumeID: "volume-1")
        let summary = try await service.inspect(target)
        let result = try await service.deleteAllContents(of: target, matching: summary)
        XCTAssertEqual(result.remainingItemCount, 0)
        XCTAssertTrue(result.failures.isEmpty, "Actual absence must reconcile a provider's late error")
    }

    func testActuallyRemainingHiddenFileStillReportsFailure() async throws {
        let root = temporaryDirectory()
        let file = root.appendingPathComponent(".cannot-remove")
        try Data("keep".utf8).write(to: file)
        let service = USBFolderCleanupService(fileManager: RefusingRemovalFileManager(),
                                            volumeIdentity: { _ in "volume-1" },
                                            startAccessing: { _ in true }, stopAccessing: { _ in })
        let target = destination(root, volumeID: "volume-1")
        let before = try await service.inspect(target)
        let result = try await service.deleteAllContents(of: target, matching: before)
        XCTAssertEqual(result.remainingItemCount, 1)
        XCTAssertEqual(result.deletedItemCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testInspectAndDeleteAcquireScopeOnOriginalBookmarkURL() async throws {
        let parent = temporaryDirectory()
        let root = parent.appendingPathComponent("SD CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("test only".utf8).write(to: root.appendingPathComponent("inside.txt"))
        let original = try XCTUnwrap(URL(string: root.absoluteString + "./"))
        XCTAssertNotEqual(original.absoluteString, original.standardizedFileURL.absoluteString)
        let access = CleanupScopeProbe(expected: original.absoluteString)
        let service = USBFolderCleanupService(
            volumeIdentity: { _ in "volume-1" },
            startAccessing: { access.start($0) },
            stopAccessing: { access.stop($0) }
        )
        let target = destination(original, volumeID: "volume-1")
        let summary = try await service.inspect(target)
        XCTAssertEqual(summary.fileCount, 1)
        let result = try await service.deleteAllContents(of: target, matching: summary)
        XCTAssertEqual(result.deletedItemCount, 1)
        XCTAssertEqual(result.remainingItemCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(access.started, [original.absoluteString, original.absoluteString])
        XCTAssertEqual(access.stopped, access.started)
    }

    func testDeniedSecurityScopeNeverDeletesEvenReadableLocalFolder() async throws {
        let root = temporaryDirectory()
        let protectedFile = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: protectedFile)
        let target = destination(root, volumeID: "volume-1")
        let summary = try await makeService(volumeID: "volume-1").inspect(target)
        let service = USBFolderCleanupService(
            volumeIdentity: { _ in "volume-1" },
            startAccessing: { _ in false },
            stopAccessing: { _ in XCTFail("Do not release a scope that was not acquired") }
        )
        do {
            _ = try await service.deleteAllContents(of: target, matching: summary)
            XCTFail("Denied access must stop deletion")
        } catch let error as USBFolderCleanupError {
            XCTAssertEqual(error, .destinationUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: protectedFile), Data("keep".utf8))
    }

    func testInspectionCountsHiddenAndNestedItemsAndReportsFileSystem() async throws {
        let root = temporaryDirectory().appendingPathComponent("SD CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("visible.bin"))
        try Data([4]).write(to: root.appendingPathComponent(".hidden"))
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([5, 6]).write(to: nested.appendingPathComponent("inside.bin"))
        let service = makeService(volumeID: "volume-1")

        let summary = try await service.inspect(destination(root, volumeID: "volume-1"))

        XCTAssertEqual(summary.folderName, "SD CARD")
        XCTAssertEqual(summary.fileSystemDescription, "ExFAT")
        XCTAssertEqual(summary.fileCount, 3)
        XCTAssertEqual(summary.directoryCount, 1)
        XCTAssertEqual(summary.totalBytes, 6)
        XCTAssertEqual(summary.totalItemCount, 4)
    }

    func testDeletionRejectsChangedContentsBeforeRemovingAnything() async throws {
        let root = temporaryDirectory().appendingPathComponent("SD CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: original)
        let service = makeService(volumeID: "volume-1")
        let target = destination(root, volumeID: "volume-1")
        let inspected = try await service.inspect(target)
        let added = root.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: added)

        do {
            _ = try await service.deleteAllContents(of: target, matching: inspected)
            XCTFail("Changed contents must require a fresh confirmation")
        } catch let error as USBFolderCleanupError {
            XCTAssertEqual(error, .contentsChanged)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.path))
    }

    func testDeletionRemovesAllSelectedFolderContentsButPreservesRootAndSibling() async throws {
        let parent = temporaryDirectory()
        let root = parent.appendingPathComponent("SD CARD", isDirectory: true)
        let sibling = parent.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: sibling)
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("two".utf8).write(to: nested.appendingPathComponent("two.txt"))
        let service = makeService(volumeID: "volume-1")
        let target = destination(root, volumeID: "volume-1")
        let inspected = try await service.inspect(target)

        let result = try await service.deleteAllContents(of: target, matching: inspected)

        XCTAssertEqual(result.deletedItemCount, inspected.totalItemCount)
        XCTAssertEqual(result.remainingItemCount, 0)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testStaleDestinationIsRejectedWithoutDeletingContents() async throws {
        let root = temporaryDirectory()
        let file = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let service = makeService(volumeID: "volume-1")
        let stale = USBBookmarkDestination(
            url: root,
            volumeID: "volume-1",
            displayName: "SD CARD",
            isStale: true,
            formatDescription: "ExFAT"
        )

        do {
            _ = try await service.inspect(stale)
            XCTFail("A stale bookmark must not be used for destructive work")
        } catch let error as USBFolderCleanupError {
            XCTAssertEqual(error, .staleDestination)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testSymlinkSelectedAsRootIsRejectedWithoutDeletingTargetContents() async throws {
        let parent = temporaryDirectory()
        let target = parent.appendingPathComponent("actual", isDirectory: true)
        let link = parent.appendingPathComponent("selected-link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let protectedFile = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: protectedFile)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let service = makeService(volumeID: "volume-1")

        do {
            _ = try await service.inspect(destination(link, volumeID: "volume-1"))
            XCTFail("A symbolic-link root must never be used for destructive work")
        } catch let error as USBFolderCleanupError {
            XCTAssertEqual(error, .destinationUnavailable)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedFile.path))
    }

    private func makeService(volumeID: String) -> USBFolderCleanupService {
        USBFolderCleanupService(
            volumeIdentity: { _ in volumeID },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
    }

    private func destination(_ url: URL, volumeID: String) -> USBBookmarkDestination {
        USBBookmarkDestination(
            url: url,
            volumeID: volumeID,
            displayName: url.lastPathComponent,
            isStale: false,
            formatDescription: "ExFAT"
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class RemovedThenErrorFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        try super.removeItem(at: URL)
        throw CocoaError(.fileNoSuchFile)
    }
}

private final class DelayedRemovalFileManager: FileManager, @unchecked Sendable {
    private var pending: [URL] = []
    private var refreshCount = 0
    override func removeItem(at URL: URL) throws { pending.append(URL) }
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                     options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        if !pending.isEmpty {
            refreshCount += 1
            if refreshCount >= 2 {
                for item in pending { try super.removeItem(at: item) }
                pending = []
            }
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

private final class RefusingRemovalFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class CleanupScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: String
    private var starts: [String] = []
    private var stops: [String] = []
    init(expected: String) { self.expected = expected }
    var started: [String] { lock.withLock { starts } }
    var stopped: [String] { lock.withLock { stops } }
    func start(_ url: URL) -> Bool {
        lock.withLock { starts.append(url.absoluteString) }
        return url.absoluteString == expected
    }
    func stop(_ url: URL) {
        lock.withLock { stops.append(url.absoluteString) }
    }
}
