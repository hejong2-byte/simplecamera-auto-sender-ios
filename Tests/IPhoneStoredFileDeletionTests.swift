import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneStoredFileDeletionTests: XCTestCase {
    func testOnlySelectedLocalFileIsDeletedAndReceiptRecordIsPreserved() throws {
        let catalog = try makeCatalog()
        let firstURL = try write("first.txt", in: catalog.receivedDirectory)
        let secondURL = try write("second.txt", in: catalog.receivedDirectory)
        let stagingURL = try write("download.partial", in: catalog.stagingDirectory)
        let record = IPhoneReceivedFileRecord(
            deliveryID: UUID(), originalName: "first.txt", storedName: "first.txt",
            size: 4, sha256: String(repeating: "a", count: 64), receivedAt: .now
        )
        try catalog.save(record)
        let first = try XCTUnwrap(catalog.refresh().first { $0.name == "first.txt" })

        let result = catalog.delete([first])

        XCTAssertEqual(result.deletedIDs, [first.id])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(try catalog.refresh().map(\.name), ["second.txt"])
        XCTAssertEqual(catalog.record(for: record.deliveryID), record)
    }

    func testChangedFileIsKeptAndOtherSelectedFileStillDeletes() throws {
        let catalog = try makeCatalog()
        _ = try write("first.txt", in: catalog.receivedDirectory)
        let changedURL = try write("changed.txt", in: catalog.receivedDirectory)
        let selection = try catalog.refresh()
        try Data("a newer file with different data".utf8).write(to: changedURL)

        let result = catalog.delete(selection)

        XCTAssertEqual(result.deletedIDs.count, 1)
        XCTAssertEqual(result.failures.map(\.name), ["changed.txt"])
        XCTAssertEqual(try String(contentsOf: changedURL, encoding: .utf8), "a newer file with different data")
        XCTAssertEqual(try catalog.refresh().map(\.name), ["changed.txt"])
    }

    func testSameSizeFileWithNewModificationDateIsNotDeleted() throws {
        let catalog = try makeCatalog()
        let url = try write("changed.txt", in: catalog.receivedDirectory)
        let file = try XCTUnwrap(catalog.refresh().first)
        try FileManager.default.setAttributes(
            [.modificationDate: file.modifiedAt.addingTimeInterval(10)],
            ofItemAtPath: url.path
        )

        let result = catalog.delete([file])

        XCTAssertTrue(result.deletedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testForgedOutsidePathIsNotDeleted() throws {
        let catalog = try makeCatalog()
        let outside = try write("outside.txt", in: catalog.receivedDirectory.deletingLastPathComponent())
        let forged = snapshot(outside)

        let result = catalog.delete([forged])

        XCTAssertTrue(result.deletedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "data")
    }

    func testDirectoriesAndSymbolicLinksAreNotDeleted() throws {
        let catalog = try makeCatalog()
        let directory = catalog.receivedDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let child = try write("keep.txt", in: directory)
        let target = try write("outside.txt", in: catalog.receivedDirectory.deletingLastPathComponent())
        let link = catalog.receivedDirectory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = catalog.delete([snapshot(directory), snapshot(link)])

        XCTAssertTrue(result.deletedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "data")
    }

    func testFileWhoseReceiptIsStillPendingIsProtected() throws {
        let catalog = try makeCatalog()
        let url = try write("pending.txt", in: catalog.receivedDirectory)
        let file = try XCTUnwrap(catalog.refresh().first)

        let result = catalog.delete([file], protectedFileNames: ["pending.txt"])

        XCTAssertTrue(result.deletedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures.first?.message.contains("수신") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingFileDoesNotClaimSuccessfulDeletion() throws {
        let catalog = try makeCatalog()
        let url = try write("missing.txt", in: catalog.receivedDirectory)
        let file = try XCTUnwrap(catalog.refresh().first)
        try FileManager.default.removeItem(at: url)

        let result = catalog.delete([file])

        XCTAssertTrue(result.deletedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(try catalog.refresh().isEmpty)
    }

    func testNewReceiptAtSameFileNameCannotBeDeletedUsingOldSelection() throws {
        let catalog = try makeCatalog()
        let url = try write("reused.txt", in: catalog.receivedDirectory)
        let oldSelection = try XCTUnwrap(catalog.refresh().first)
        try catalog.save(IPhoneReceivedFileRecord(
            deliveryID: UUID(), originalName: "reused.txt", storedName: "reused.txt",
            size: 4, sha256: String(repeating: "b", count: 64), receivedAt: .now
        ))

        let result = catalog.delete([oldSelection])

        XCTAssertTrue(result.deletedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func makeCatalog() throws -> IPhoneReceivedFileCatalog {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try IPhoneReceivedFileCatalog(
            receivedDirectory: root.appendingPathComponent("Received", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("Staging", isDirectory: true),
            recordsFileURL: root.appendingPathComponent("records.json")
        )
    }

    private func write(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("data".utf8).write(to: url)
        return url
    }

    private func snapshot(_ url: URL) -> IPhoneStoredFile {
        IPhoneStoredFile(
            id: url.standardizedFileURL.path, url: url, name: url.lastPathComponent,
            size: 4, modifiedAt: .now, receivedRecord: nil
        )
    }
}
