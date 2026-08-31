import XCTest
@testable import SimpleCameraAutoSender

final class AutomaticTransferProgressTests: XCTestCase {
    func testUnclassifiedCandidatesAreNotCountedAsTransfers() async {
        let store = AutomaticTransferProgressStore()
        let reporter = AutomaticTransferProgressReporter(store: store)
        reporter.beginScanning()
        reporter.beginPreparing(currentIndex: 1, knownCount: 11)

        var iterator = store.updates().makeAsyncIterator()
        let progress = await iterator.next()

        XCTAssertEqual(progress?.totalCount, 0)
        XCTAssertEqual(progress?.uploadedCount, 0)
        XCTAssertEqual(progress?.failedCount, 0)
    }

    func testEmptyRunDoesNotShowOneHundredPercent() async {
        let store = AutomaticTransferProgressStore()
        let reporter = AutomaticTransferProgressReporter(store: store)
        reporter.finishRun(uploadedCount: 0, failedCount: 0, failureCategories: [])
        var iterator = store.updates().makeAsyncIterator()
        let progress = await iterator.next()

        XCTAssertEqual(progress?.percent, 0)
    }

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

    func testReporterAggregatesCompletedAndCurrentFileBytes() async {
        let store = AutomaticTransferProgressStore()
        let reporter = AutomaticTransferProgressReporter(store: store)

        reporter.beginScanning()
        reporter.beginPreparing(currentIndex: 1, knownCount: 2)
        reporter.registerPreparedFile(bytes: 10)
        reporter.registerPreparedFile(bytes: 10)
        reporter.beginUpload(currentIndex: 1, fileBytes: 10)
        reporter.reportUpload(sent: 5, total: 10)

        var iterator = store.updates().makeAsyncIterator()
        let received = await iterator.next()

        XCTAssertEqual(received?.stage, .uploading)
        XCTAssertEqual(received?.currentIndex, 1)
        XCTAssertEqual(received?.totalCount, 2)
        XCTAssertEqual(received?.totalBytes, 20)
        XCTAssertEqual(received?.displayedBytesSent, 5)
        XCTAssertEqual(received?.percent, 25)
    }
}
