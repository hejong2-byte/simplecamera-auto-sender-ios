import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneLocalReceiveJobStoreTests: XCTestCase {
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
        try store.save(job)

        let reopened = try IPhoneLocalReceiveJobStore(fileURL: stateURL)

        XCTAssertEqual(try reopened.load().version, 1)
        XCTAssertEqual(try reopened.load().jobs, [job])
        XCTAssertEqual(try reopened.load().jobs.first?.stage, .ackPending)
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
