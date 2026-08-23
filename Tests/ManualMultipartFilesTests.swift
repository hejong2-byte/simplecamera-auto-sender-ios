import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualMultipartFilesTests: XCTestCase {
    func testCreatesExactSizedPartsAndPreservesEveryByte() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.bin")
        let partsDirectory = directory.appendingPathComponent("parts", isDirectory: true)
        let sourceBytes = Data((0..<10).map(UInt8.init))
        try sourceBytes.write(to: sourceURL)

        let parts = try ManualMultipartFiles.makeParts(
            source: sourceURL,
            directory: partsDirectory,
            partBytes: 4
        )

        XCTAssertEqual(try parts.map(fileSize), [4, 4, 2])
        XCTAssertEqual(parts.map(\.lastPathComponent), [
            "part-00001.bin",
            "part-00002.bin",
            "part-00003.bin"
        ])
        let joined = try parts.reduce(into: Data()) { result, url in
            result.append(try Data(contentsOf: url))
        }
        XCTAssertEqual(joined, sourceBytes)
    }

    func testFillsIntermediatePartsAcrossShortReads() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.bin")
        let partsDirectory = directory.appendingPathComponent("parts", isDirectory: true)
        try Data((0..<10).map(UInt8.init)).write(to: sourceURL)

        let parts = try ManualMultipartFiles.makeParts(
            source: sourceURL,
            directory: partsDirectory,
            partBytes: 4,
            reader: { handle, requestedBytes in
                try handle.read(upToCount: min(2, requestedBytes)) ?? Data()
            }
        )

        XCTAssertEqual(try parts.map(fileSize), [4, 4, 2])
    }

    func testRejectsEmptySource() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("empty.bin")
        try Data().write(to: sourceURL)

        XCTAssertThrowsError(
            try ManualMultipartFiles.makeParts(
                source: sourceURL,
                directory: directory.appendingPathComponent("parts", isDirectory: true),
                partBytes: 4
            )
        )
    }

    private func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualMultipartFilesTests-(UUID().uuidString)", isDirectory: true)
    }
}
