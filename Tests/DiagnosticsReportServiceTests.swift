import XCTest
@testable import SimpleCameraAutoSender

final class DiagnosticsReportServiceTests: XCTestCase {
    private func snapshot(error: String = "secret-token /private/name.hwp receiver-123 message-body") -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(app: AppVersionInfo(version: "0.3.50", build: "61"),
            receive: USBReceiveProgress(stage: .failed, deliveryID: UUID(),
                fileName: "private-name.hwp", currentIndex: 2, totalCount: 3,
                completedCount: 1, bytesReceived: 128, totalBytes: 256,
                startedAt: Date(timeIntervalSince1970: 1234), expiresAt: nil,
                errorMessage: error, detail: "message-body secret-token",
                sourceFileIDs: ["receiver-123"], zipSelections: ["private/path": ["name.hwp"]]),
            manual: ManualTransferProgress(batchID: UUID(), kind: .file,
                selectedCount: 4, currentIndex: 2, uploadedCount: 1, failedCount: 1,
                stage: .failed, totalBytes: 1024, confirmedBytes: 512, taskBytesSent: 0,
                retryAttempt: 2, failure: .server(statusCode: 503, code: "secret-token")),
            capturedAt: Date(timeIntervalSince1970: 5678),
            copy: USBReceiveProgress(stage: .paused, deliveryID: UUID(),
                fileName: "private-copy-name.zip", currentIndex: 3, totalCount: 5,
                completedCount: 2, bytesReceived: 2048, totalBytes: 4096,
                startedAt: nil, expiresAt: nil, errorMessage: "secret-token",
                sourceFileIDs: ["receiver-123"]),
            copyCheckpointAt: Date(timeIntervalSince1970: 5000),
            receiveOutcomeAt: Date(timeIntervalSince1970: 4500))
    }

    func testReportRetainsUsefulCountersAndDropsPrivacyCanaries() throws {
        let data = try DiagnosticsReportService().encode(snapshot())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for canary in ["secret-token", "private", "name.hwp", "receiver-123", "message-body", "deliveryID", "batchID", "errorMessage", "zipSelections"] {
            XCTAssertFalse(text.contains(canary), "Leaked \(canary)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? String, "0.3.50")
        XCTAssertEqual(json["build"] as? String, "61")
        let operations = try XCTUnwrap(json["operations"] as? [[String: Any]])
        let receive = try XCTUnwrap(operations.first { $0["operation"] as? String == "receive" })
        XCTAssertEqual(receive["stage"] as? String, "failed")
        XCTAssertEqual(receive["bytesCompleted"] as? Int, 128)
        XCTAssertEqual(receive["errorPresent"] as? Bool, true)
        let manual = try XCTUnwrap(operations.first { $0["operation"] as? String == "manual" })
        XCTAssertEqual(manual["httpStatus"] as? Int, 503)
        XCTAssertEqual(manual["retryAttempt"] as? Int, 2)
        let copy = try XCTUnwrap(operations.first { $0["operation"] as? String == "usbCopy" })
        XCTAssertEqual(copy["stage"] as? String, "paused")
        XCTAssertEqual(copy["bytesCompleted"] as? Int, 2048)
        XCTAssertEqual(copy["completedCount"] as? Int, 2)
        XCTAssertEqual(copy["checkpointAt"] as? Double, 5000)
        XCTAssertEqual(receive["outcomeAt"] as? Double, 4500)
        XCTAssertEqual(json["capturedAt"] as? Double, 5678)
    }

    func testOnlyKnownErrorDomainAndNumericCodeCanEscape() throws {
        let text = String(decoding: try DiagnosticsReportService().encode(snapshot(error:
            "Error Domain=NSURLErrorDomain Code=-1001 UserInfo={token=secret-token}")), as: UTF8.self)
        XCTAssertTrue(text.contains("NSURLErrorDomain"))
        XCTAssertTrue(text.contains("-1001"))
        XCTAssertFalse(text.contains("secret-token"))
        let actual = String(decoding: try DiagnosticsReportService().encode(snapshot(error:
            "NSFileProviderErrorDomain · -2001")), as: UTF8.self)
        XCTAssertTrue(actual.contains("NSFileProviderErrorDomain"))
        XCTAssertTrue(actual.contains("-2001"))
        let unknown = String(decoding: try DiagnosticsReportService().encode(snapshot(error:
            "Error Domain=secret-token Code=123 UserInfo={message-body}")), as: UTF8.self)
        XCTAssertFalse(unknown.contains("secret-token"))
        XCTAssertFalse(unknown.contains("\"errorCode\""))
    }

    func testUniqueShareFolderCleanupPreservesOtherReportsAndOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.hwp")
        try Data("original".utf8).write(to: original)
        let service = DiagnosticsReportService(temporaryRoot: root)
        let first = try service.create(snapshot())
        let second = try service.create(snapshot())
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        try service.cleanup(first)
        try service.cleanup(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertThrowsError(try service.cleanup(DiagnosticsReportFile(url: original, directory: root)))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }
}
