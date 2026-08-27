import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneReceivedFileCatalogTests: XCTestCase {
    func testRefreshUsesFinalDirectoryAsTruthAndSortsNewestFirst() throws {
        let root = temporaryDirectory()
        let received = root.appendingPathComponent("받은 파일", isDirectory: true)
        let staging = root.appendingPathComponent("ReceiveStaging", isDirectory: true)
        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: received,
            stagingDirectory: staging,
            recordsFileURL: root.appendingPathComponent("received-files.json")
        )
        let old = received.appendingPathComponent("old.pdf")
        let newest = received.appendingPathComponent("new.hwp")
        let hidden = received.appendingPathComponent(".unfinished.partial")
        try Data("old".utf8).write(to: old)
        try Data("new".utf8).write(to: newest)
        try Data("partial".utf8).write(to: hidden)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newest.path
        )
        let record = IPhoneReceivedFileRecord(
            deliveryID: UUID(),
            originalName: "new.hwp",
            storedName: "new.hwp",
            size: 3,
            sha256: String(repeating: "b", count: 64),
            receivedAt: Date(timeIntervalSince1970: 200)
        )
        try catalog.save(record)

        let files = try catalog.refresh()
        let stagingValues = try staging.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )

        XCTAssertEqual(files.map(\.name), ["new.hwp", "old.pdf"])
        XCTAssertEqual(files.first?.receivedRecord, record)
        XCTAssertEqual(files.first?.id, newest.standardizedFileURL.path)
        XCTAssertTrue(stagingValues.isExcludedFromBackup == true)
    }

    func testMissingFinalFileIsNotRecreatedFromMetadata() throws {
        let root = temporaryDirectory()
        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: root.appendingPathComponent("받은 파일", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("ReceiveStaging", isDirectory: true),
            recordsFileURL: root.appendingPathComponent("received-files.json")
        )
        try catalog.save(IPhoneReceivedFileRecord(
            deliveryID: UUID(),
            originalName: "missing.zip",
            storedName: "missing.zip",
            size: 10,
            sha256: String(repeating: "c", count: 64),
            receivedAt: Date()
        ))

        XCTAssertEqual(try catalog.refresh(), [])
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
