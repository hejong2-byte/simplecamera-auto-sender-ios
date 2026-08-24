import XCTest
@testable import SimpleCameraAutoSender

final class AutomaticTransferProgressTests: XCTestCase {
    func testPercentUsesCompletedAndCurrentActualBytes() {
        let progress = AutomaticTransferProgress(
            runID: UUID(),
            stage: .uploading,
            currentIndex: 2,
            totalCount: 3,
            uploadedCount: 1,
            failedCount: 0,
            totalBytes: 1_000,
            completedBytes: 400,
            currentBytesSent: 250,
            currentBytesTotal: 300,
            failureCategories: []
        )

        XCTAssertEqual(progress.displayedBytesSent, 650)
        XCTAssertEqual(progress.percent, 65)
    }

    func testLateSubscriberImmediatelyReceivesLatestProgress() async {
        let store = AutomaticTransferProgressStore()
        let latest = AutomaticTransferProgress.scanning(runID: UUID())
        store.publish(latest)

        var iterator = store.updates().makeAsyncIterator()
        let received = await iterator.next()

        XCTAssertEqual(received, latest)
    }
}
