import Foundation
import XCTest
import ZIPFoundation
@testable import SimpleCameraAutoSender

final class SafeZIPExtractionProgressTests: XCTestCase {
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
