import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class ContentViewModelTests: XCTestCase {
    func testEnableAutomaticSendingRecordsCurrentBaseline() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let expected = Date(timeIntervalSince1970: 1_234)
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(),
            ledger: ledger,
            uploader: NoOpUploader(),
            now: { expected },
            send: { _ in SyncEnqueueSummary(discovered: 0, queued: 0, failed: 0) }
        )

        try await model.enableAutomaticSending()

        let baseline = try await ledger.baseline()
        XCTAssertEqual(baseline, expected)
    }

    func testSaveCredentialNeverPublishesStoredValue() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(),
            ledger: ledger,
            uploader: NoOpUploader(),
            now: Date.init,
            send: { _ in SyncEnqueueSummary(discovered: 0, queued: 0, failed: 0) }
        )

        try await model.saveCredential("secret-value")

        XCTAssertTrue(model.hasCredential)
        XCTAssertFalse(String(describing: model).contains("secret-value"))
    }

    private func temporaryLedgerURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("ledger.json")
    }
}

private final class NoOpUploader: UploadCoordinating, @unchecked Sendable {
    func enqueue(assetID: String, fileURL: URL) async throws {}
    func reconnect() async {}
    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}
