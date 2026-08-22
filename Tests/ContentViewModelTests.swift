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
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) }
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
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) }
        )

        try await model.saveCredential("secret-value")

        XCTAssertTrue(model.hasCredential)
        XCTAssertFalse(String(describing: model).contains("secret-value"))
    }

    func testManualSelectionPublishesExactBatchSummary() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let credentials = InMemoryCredentialStore()
        try credentials.save("Bearer test")
        let expected = ManualMediaTransferSummary(
            selected: 3,
            uploaded: 2,
            failed: 1,
            failureCategories: [.network]
        )
        let model = ContentViewModel(
            credentialStore: credentials,
            ledger: ledger,
            uploader: NoOpUploader(),
            now: Date.init,
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) },
            manualSend: { selection, kind in
                XCTAssertEqual(selection.assetIdentifiers, ["a", "b", "c"])
                XCTAssertEqual(kind, .video)
                return expected
            },
            photoAuthorizationStatus: .authorized
        )
        try await model.saveCredential("Bearer test")

        await model.sendSelectedMedia(
            selection: ManualMediaSelection(
                assetIdentifiers: ["a", "b", "c"],
                unavailableCount: 0
            ),
            kind: .video
        )

        XCTAssertEqual(model.lastManualSummary, expected)
        XCTAssertEqual(model.manualTransferMessage, "동영상 전송: 2개 완료, 1개 실패 (네트워크 연결 확인 필요)")
        XCTAssertFalse(model.isManualTransferWorking)
    }

    private func temporaryLedgerURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("ledger.json")
    }
}

private final class NoOpUploader: UploadCoordinating, @unchecked Sendable {
    func upload(assetID: String, fileURL: URL) async throws {}
    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}
