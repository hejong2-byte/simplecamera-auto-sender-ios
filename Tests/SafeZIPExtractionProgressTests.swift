import Foundation
import XCTest
import ZIPFoundation
@testable import SimpleCameraAutoSender

final class SafeZIPExtractionProgressTests: XCTestCase {
    func testMetadataAndFolderSelectionDoNotExtractUnselectedEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("document".utf8).write(to: input.appendingPathComponent("docs/report.txt"))
        try Data("skip".utf8).write(to: input.appendingPathComponent("other.txt"))
        let zip = root.appendingPathComponent("archive.zip")
        try FileManager.default.zipItem(at: input, to: zip, shouldKeepParent: false)
        let extractor = SafeZIPExtractor(fileManager: .default)

        let entries = try extractor.contents(of: zip)
        XCTAssertTrue(entries.contains { $0.path == "docs/report.txt" && $0.size == 8 && !$0.isDirectory })
        XCTAssertTrue(entries.contains { $0.path == "docs" && $0.isDirectory })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("out").path))

        let output = try extractor.extract(zip, to: root.appendingPathComponent("out"), selectedPaths: ["docs"])
        XCTAssertEqual(output.files.map(\.relativePath), ["docs/report.txt"])
        XCTAssertEqual(output.totalBytes, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("out/other.txt").path))
    }

    func testEmptyAndUnknownZIPSelectionFailBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: source)
        let zip = root.appendingPathComponent("archive.zip")
        try FileManager.default.zipItem(at: source, to: zip)
        let extractor = SafeZIPExtractor(fileManager: .default)
        XCTAssertThrowsError(try extractor.extract(zip, to: root.appendingPathComponent("empty"), selectedPaths: []))
        XCTAssertThrowsError(try extractor.extract(zip, to: root.appendingPathComponent("unknown"), selectedPaths: ["missing"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unknown").path))
    }

    func testCP949EntryNameWithoutUTF8FlagIsRestored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zip = root.appendingPathComponent("windows-korean.zip")
        let fixture = try XCTUnwrap(Data(base64Encoded:
            "UEsDBBQAAAAAAAAAAAAeEYlcEAAAABAAAAANAAAAx9Gx2yC5rrytLnR4dGhlbGxvIGtvcmVhbiB6aXBQSwECFAAUAAAAAAAAAAAAHhGJXBAAAAAQAAAADQAAAAAAAAAAAAAAAAAAAAAAx9Gx2yC5rrytLnR4dFBLBQYAAAAAAQABADsAAAA7AAAAAAA="
        ))
        try fixture.write(to: zip)

        let output = try SafeZIPExtractor(fileManager: .default)
            .extract(zip, to: root.appendingPathComponent("out"))

        XCTAssertEqual(output.files.map(\.relativePath), ["한글 문서.txt"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(output.files.first).url), Data("hello korean zip".utf8))
    }

    func testSingleLargeEntryReportsBytesBeforeEntryCompletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("large.bin")
        let payload = Data(repeating: 0x5a, count: 8 * 1_024 * 1_024)
        try payload.write(to: input)
        let zip = root.appendingPathComponent("large.zip")
        try FileManager.default.zipItem(at: input, to: zip, compressionMethod: .deflate)
        var samples: [(Int64, Int64, String, Int)] = []
        let output = try SafeZIPExtractor(fileManager: .default).extract(zip, to: root.appendingPathComponent("out")) {
            bytes, total, name, completed, _ in
            samples.append((bytes, total, name, completed))
        }
        XCTAssertTrue(samples.contains { $0.0 > 0 && $0.0 < $0.1 && $0.3 == 0 },
                      "Progress must move inside a large entry, not only after the file is done")
        XCTAssertEqual(samples.last?.0, Int64(payload.count))
        XCTAssertEqual(samples.last?.1, Int64(payload.count))
        XCTAssertEqual(samples.last?.2, "large.bin")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(output.files.first).url), payload)
    }
}
