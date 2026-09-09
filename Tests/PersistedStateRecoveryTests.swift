import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class PersistedStateRecoveryTests: XCTestCase {
    func testCorruptUploadLedgerStartsWithAutomaticTransferDisabled() async throws {
        let fixture = try corruptFile(named: "upload-ledger.json")

        let ledger = try UploadLedger(fileURL: fixture.url)
        let baseline = try await ledger.baseline()
        let records = await ledger.allRecords()

        XCTAssertNil(baseline)
        XCTAssertEqual(records, [])
        try assertQuarantined(fixture)
    }

    func testCorruptUSBReceiveLedgerStartsWithoutCheckpoints() throws {
        let fixture = try corruptFile(named: "usb-ledger.json")

        let ledger = try USBReceiveLedger(fileURL: fixture.url)

        XCTAssertEqual(ledger.allCheckpoints(), [])
        try assertQuarantined(fixture)
    }

    func testCorruptLocalReceiveJobStoreStartsWithoutJobs() throws {
        let fixture = try corruptFile(named: "local-jobs.json")

        let store = try IPhoneLocalReceiveJobStore(fileURL: fixture.url)

        XCTAssertEqual(try store.load(), IPhoneLocalReceiveJobState(version: 1, jobs: []))
        try assertQuarantined(fixture)
    }

    func testCorruptReceivedFileCatalogPreservesAndShowsReceivedFiles() throws {
        let root = temporaryDirectory()
        let received = root.appendingPathComponent("받은 파일", isDirectory: true)
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        let receivedFile = received.appendingPathComponent("보존할 파일.txt")
        try Data("user data".utf8).write(to: receivedFile)
        let fixture = try corruptFile(named: "received-records.json", in: root)

        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: received,
            stagingDirectory: root.appendingPathComponent("ReceiveStaging", isDirectory: true),
            recordsFileURL: fixture.url
        )

        XCTAssertEqual(try catalog.refresh().map(\.name), ["보존할 파일.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: receivedFile.path))
        try assertQuarantined(fixture)
    }

    func testCorruptUSBDeletionDecisionsStartWithoutPendingDeletion() throws {
        let fixture = try corruptFile(named: "deletion-decisions.json")

        let store = try IPhoneUSBDeletionDecisionStore(fileURL: fixture.url)

        XCTAssertEqual(store.pending(), [])
        try assertQuarantined(fixture)
    }

    private typealias CorruptFixture = (url: URL, data: Data)

    private func corruptFile(
        named name: String,
        in suppliedDirectory: URL? = nil
    ) throws -> CorruptFixture {
        let directory = suppliedDirectory ?? temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let data = Data("{not valid json".utf8)
        try data.write(to: url)
        return (url, data)
    }

    private func assertQuarantined(
        _ fixture: CorruptFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let prefix = fixture.url.lastPathComponent + ".corrupt-"
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: fixture.url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
        XCTAssertEqual(quarantined.count, 1, file: file, line: line)
        if let backup = quarantined.first {
            XCTAssertEqual(try Data(contentsOf: backup), fixture.data, file: file, line: line)
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
