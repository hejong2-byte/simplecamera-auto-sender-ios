import XCTest
@testable import SimpleCameraAutoSender

final class ManualTransferProgressTests: XCTestCase {
    func testPercentUsesConfirmedAndCurrentTaskBytes() {
        let progress = ManualTransferProgress.fixture(
            totalBytes: 200,
            confirmedBytes: 100,
            taskBytesSent: 34
        )

        XCTAssertEqual(progress.displayedBytesSent, 134)
        XCTAssertEqual(progress.percent, 67)
    }

    func testPercentClampsAndZeroLengthIsZero() {
        XCTAssertEqual(ManualTransferProgress.fixture(totalBytes: 0).percent, 0)
        XCTAssertEqual(
            ManualTransferProgress.fixture(
                totalBytes: 10,
                confirmedBytes: 10,
                taskBytesSent: 5
            ).percent,
            100
        )
    }

    func testFailureImmediatelyIncrementsBatchCount() {
        let failed = ManualTransferProgress.fixture(
            selected: 3,
            uploaded: 1,
            failed: 1
        )

        XCTAssertEqual(failed.completedCount, 2)
    }
}

private extension ManualTransferProgress {
    static func fixture(
        selected: Int = 1,
        uploaded: Int = 0,
        failed: Int = 0,
        totalBytes: Int64 = 1,
        confirmedBytes: Int64 = 0,
        taskBytesSent: Int64 = 0
    ) -> ManualTransferProgress {
        ManualTransferProgress(
            batchID: UUID(),
            kind: .video,
            selectedCount: selected,
            currentIndex: 1,
            uploadedCount: uploaded,
            failedCount: failed,
            stage: failed > 0 ? .failed : .uploading,
            totalBytes: totalBytes,
            confirmedBytes: confirmedBytes,
            taskBytesSent: taskBytesSent,
            retryAttempt: 0,
            failure: nil
        )
    }
}
