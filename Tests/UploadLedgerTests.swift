import XCTest
@testable import SimpleCameraAutoSender

final class UploadLedgerTests: XCTestCase {
    func testUploadedAssetCannotReturnToQueued() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        try await ledger.recordDiscovery(id: "asset-1", createdAt: .now)
        try await ledger.markQueued(id: "asset-1", taskIdentifier: 7)
        try await ledger.markUploaded(id: "asset-1")
        try await ledger.markQueued(id: "asset-1", taskIdentifier: 8)
        let state = try await ledger.record(id: "asset-1")?.state
        XCTAssertEqual(state, .uploaded)
    }

    func testFailureRemainsRetryable() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        try await ledger.recordDiscovery(id: "asset-2", createdAt: .now)
        try await ledger.markFailed(id: "asset-2", category: .network)
        let retryableIDs = try await ledger.retryableRecords().map(\.id)
        XCTAssertEqual(retryableIDs, ["asset-2"])
    }

    func testBaselinePersistsAcrossInstances() async throws {
        let url = temporaryLedgerURL()
        let expected = Date(timeIntervalSince1970: 1_234)
        let first = try UploadLedger(fileURL: url)
        try await first.setBaseline(expected)

        let reopened = try UploadLedger(fileURL: url)
        let actual = try await reopened.baseline()
        XCTAssertEqual(actual, expected)
    }

    private func temporaryLedgerURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("ledger.json")
    }
}
