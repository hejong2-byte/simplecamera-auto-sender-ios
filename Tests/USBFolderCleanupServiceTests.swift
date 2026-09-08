import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBFolderCleanupServiceTests: XCTestCase {
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
