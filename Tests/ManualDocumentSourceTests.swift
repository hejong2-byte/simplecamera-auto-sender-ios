import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualDocumentSourceTests: XCTestCase {
    func testCopiesSelectedOriginalBytesNameAndMIMEWithoutChangingSource() async throws {
        let root = try fixture()
        for (name, mime) in [("카카오톡 문서.pdf", "application/pdf"), ("원본.xyzcustom", "application/octet-stream")] {
            let original = root.appendingPathComponent(name)
            let bytes = Data("chosen original: \(name)".utf8)
            try bytes.write(to: original)
            let before = try UploadFileFingerprinter.fingerprint(fileURL: original)
            let exported = try await ManualDocumentSource().exportOriginal(
                fileURL: original, identifier: "document-test", to: root.appendingPathComponent("staged")
            )
            XCTAssertNotEqual(exported.fileURL, original)
            XCTAssertEqual(exported.fileName, name)
            XCTAssertEqual(exported.contentType, mime)
            XCTAssertEqual(try Data(contentsOf: exported.fileURL), bytes)
            XCTAssertEqual(try UploadFileFingerprinter.fingerprint(fileURL: original), before)
        }
    }

    func testMissingDirectorySymlinkAndEmptyFileDoNotCreateStagedJobs() async throws {
        let root = try fixture()
        let empty = root.appendingPathComponent("empty.zip")
        try Data().write(to: empty)
        let target = root.appendingPathComponent("target.txt")
        try Data("keep original".utf8).write(to: target)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let staging = root.appendingPathComponent("staged")
        for url in [root.appendingPathComponent("missing.pdf"), root, link, empty] {
            do {
                _ = try await ManualDocumentSource().exportOriginal(fileURL: url, identifier: "invalid", to: staging)
                XCTFail("Invalid selection must fail: \(url.lastPathComponent)")
            } catch {}
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep original")
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: staging.path))?.isEmpty ?? true)
    }

    func testOversizeFailsBeforeCopyAndPreservesOriginal() async throws {
        let root = try fixture()
        let original = root.appendingPathComponent("too-large.zip")
        try Data(repeating: 1, count: 6).write(to: original)
        do {
            _ = try await ManualDocumentSource(maxBytes: 5).exportOriginal(
                fileURL: original, identifier: "large", to: root.appendingPathComponent("staged")
            )
            XCTFail("Oversize file must be rejected")
        } catch let error as ManualMediaUploadError {
            XCTAssertEqual(error, .fileTooLarge(maxBytes: 5))
        }
        XCTAssertEqual(try Data(contentsOf: original).count, 6)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
