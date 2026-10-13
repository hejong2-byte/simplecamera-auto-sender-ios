import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneLocalReceiveJobStoreTests: XCTestCase {
    func testLegacyFailedJobWithoutNewKeysRequiresExplicitDurableRetryRequest() throws {
        for stagingName in [nil, "corrupt.download"] as [String?] {
            let root = temporaryDirectory()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let stateURL = root.appendingPathComponent("jobs.json")
            let file = delivery()
            let job = IPhoneLocalReceiveJob(id: file.deliveryID, delivery: file, stage: .failed,
                stagingFileName: stagingName, finalFileName: nil, bytesReceived: 4,
                retryCount: 0, lastError: "legacy failure")
            let encoded = try JSONEncoder().encode(IPhoneLocalReceiveJobState(version: 1, jobs: [job]))
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var jobs = try XCTUnwrap(document["jobs"] as? [[String: Any]])
            jobs[0].removeValue(forKey: "failureIsRetryable")
            jobs[0].removeValue(forKey: "retryRequested")
            document["jobs"] = jobs
            try JSONSerialization.data(withJSONObject: document).write(to: stateURL)
            let store = try IPhoneLocalReceiveJobStore(fileURL: stateURL)
            XCTAssertNil(store.job(for: file.deliveryID)?.retryRequested)

            try store.requestRetry(deliveryID: file.deliveryID)

            let reopened = try IPhoneLocalReceiveJobStore(fileURL: stateURL)
            let requested = try XCTUnwrap(reopened.job(for: file.deliveryID))
            XCTAssertEqual(requested.stage, .failed, "Approval queues a durable request without racing a download")
            if stagingName == nil {
                XCTAssertEqual(requested.retryRequested, true)
                XCTAssertEqual(requested.failureIsRetryable, true)
            } else {
                XCTAssertNil(requested.retryRequested, "Legacy integrity evidence must not be silently retried")
                XCTAssertEqual(requested.stagingFileName, stagingName)
            }
        }
    }

    func testRetryRequestPersistenceFailureDoesNotMutateLiveJob() throws {
        let root = temporaryDirectory()
        let stateURL = root.appendingPathComponent("jobs.json")
        let store = try IPhoneLocalReceiveJobStore(fileURL: stateURL)
        let file = delivery()
        var job = IPhoneLocalReceiveJob(id: file.deliveryID, delivery: file, stage: .failed,
            stagingFileName: nil, finalFileName: nil, bytesReceived: 4, retryCount: 0, lastError: "timeout")
        job.failureIsRetryable = true
        try store.save(job)
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.requestRetry(deliveryID: file.deliveryID))

        XCTAssertEqual(store.job(for: file.deliveryID), job)
    }

    func testJobRoundTripPreservesAckPendingStateAndProgress() throws {
        let root = temporaryDirectory()
        let stateURL = root.appendingPathComponent("local-receive-jobs.json")
        let store = try IPhoneLocalReceiveJobStore(fileURL: stateURL)
        var job = IPhoneLocalReceiveJob(
            id: UUID(),
            delivery: delivery(),
            stage: .scheduled,
            stagingFileName: nil,
            finalFileName: nil,
            bytesReceived: 0,
            retryCount: 0,
            lastError: nil
        )
        try store.save(job)
        job.stage = .ackPending
        job.stagingFileName = "payload.download"
        job.finalFileName = "업무.hwp"
        job.bytesReceived = 40
        job.retryCount = 2
        job.lastError = "ack timeout"
        job.mediaLibraryAdded = true
        job.mediaLibraryMessage = "사진 앱에도 저장했습니다."
        try store.save(job)

        let reopened = try IPhoneLocalReceiveJobStore(fileURL: stateURL)

        XCTAssertEqual(try reopened.load().version, 1)
        XCTAssertEqual(try reopened.load().jobs, [job])
        XCTAssertEqual(try reopened.load().jobs.first?.stage, .ackPending)
        XCTAssertEqual(try reopened.load().jobs.first?.mediaLibraryAdded, true)
    }

    private func delivery() -> IPhoneDelivery {
        IPhoneDelivery(
            deliveryID: UUID(),
            fileName: "업무.hwp",
            contentType: "application/x-hwp",
            size: 40,
            sha256: String(repeating: "a", count: 64),
            state: .available,
            createdAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 700),
            deliveredAt: nil
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
