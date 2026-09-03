import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneStoredFilePreviewTests: XCTestCase {
    func testPreviewReturnsOriginalURLWithoutChangingBytesOrReceiptHistory() throws {
        let catalog = try makeCatalog()
        let url = catalog.receivedDirectory.appendingPathComponent("한글 문서.txt")
        let bytes = Data("preview must be read only".utf8)
        try bytes.write(to: url)
        let record = IPhoneReceivedFileRecord(
            deliveryID: UUID(), originalName: url.lastPathComponent, storedName: url.lastPathComponent,
            size: Int64(bytes.count), sha256: String(repeating: "a", count: 64), receivedAt: .now
        )
        try catalog.save(record)
        let file = try XCTUnwrap(catalog.refresh().first)

        XCTAssertEqual(try catalog.previewURL(for: file), url.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try catalog.refresh(), [file])
        XCTAssertEqual(catalog.record(for: record.deliveryID), record)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: catalog.stagingDirectory.path).isEmpty)
    }

    func testMissingAndChangedFilesAreRejected() throws {
        let catalog = try makeCatalog()
        let url = catalog.receivedDirectory.appendingPathComponent("changed.txt")
        try Data("original".utf8).write(to: url)
        let file = try XCTUnwrap(catalog.refresh().first)
        try Data("changed contents".utf8).write(to: url)
        XCTAssertThrowsError(try catalog.previewURL(for: file))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try catalog.previewURL(for: file))
    }

    func testOutsideFileDirectoryAndSymlinkAreRejectedWithoutTouchingTargets() throws {
        let catalog = try makeCatalog()
        let outside = catalog.receivedDirectory.deletingLastPathComponent().appendingPathComponent("outside.txt")
        let bytes = Data("outside original".utf8)
        try bytes.write(to: outside)
        let link = catalog.receivedDirectory.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for url in [outside, link, catalog.receivedDirectory] {
            let file = IPhoneStoredFile(
                id: url.standardizedFileURL.path, url: url, name: url.lastPathComponent,
                size: Int64(bytes.count), modifiedAt: .now, receivedRecord: nil
            )
            XCTAssertThrowsError(try catalog.previewURL(for: file))
        }
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
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
}
