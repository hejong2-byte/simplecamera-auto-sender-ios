import XCTest
@testable import SimpleCameraAutoSender

final class USBExportProgressRecoveryTests: XCTestCase {
    func testRelaunchRestores70PercentAsInterruptedNotRunning() throws {
        let url = try checkpointURL()
        let store = USBReceiveProgressStore(fileURL: url)
        store.publish(progress(.copyingToUSB, bytes: 70))
        let restored = USBReceiveProgressStore(fileURL: url).snapshot()
        XCTAssertEqual(restored.stage, .paused)
        XCTAssertEqual(restored.percent, 70)
        XCTAssertEqual(restored.fileName, "map.zip")
        XCTAssertTrue(restored.detail?.contains("완료된 복사본이 아닙니다") == true)
    }

    func testExpirationKeepsCheckpointDespiteLateWorkerProgressAndCancellation() throws {
        let url = try checkpointURL()
        let store = USBReceiveProgressStore(fileURL: url)
        store.publish(progress(.copyingToUSB, bytes: 70))
        store.interruptExport()
        store.publish(progress(.copyingToUSB, bytes: 71))
        store.publish(progress(.cancelled, bytes: 0))
        XCTAssertEqual(store.snapshot().stage, .paused)
        XCTAssertEqual(store.snapshot().percent, 70)
        XCTAssertEqual(USBReceiveProgressStore(fileURL: url).snapshot().percent, 70)
        XCTAssertTrue(store.snapshot().detail?.contains("백그라운드") == true)
    }

    func testCompletedResultWinsExpirationRaceAndSurvivesRelaunch() throws {
        let url = try checkpointURL()
        let store = USBReceiveProgressStore(fileURL: url)
        store.publish(progress(.copyingToUSB, bytes: 70))
        store.interruptExport()
        store.publish(progress(.completed, bytes: 100))
        XCTAssertEqual(USBReceiveProgressStore(fileURL: url).snapshot().stage, .completed)
    }

    func testExplicitNewExportReplacesOldInterruptedCheckpoint() throws {
        let store = USBReceiveProgressStore(fileURL: try checkpointURL())
        store.publish(progress(.copyingToUSB, bytes: 70))
        store.interruptExport()
        store.beginExport(fileName: "next.zip", totalCount: 1)
        store.publish(progress(.copyingToUSB, bytes: 10))
        XCTAssertEqual(store.snapshot().stage, .copyingToUSB)
        XCTAssertEqual(store.snapshot().percent, 10)
    }

    func testClearedCompletionDoesNotReturnAfterRestart() throws {
        let url = try checkpointURL()
        let store = USBReceiveProgressStore(fileURL: url)
        store.publish(progress(.completed, bytes: 100))
        store.clearCompleted()
        XCTAssertEqual(USBReceiveProgressStore(fileURL: url).snapshot().stage, .idle)
    }

    func testCorruptCheckpointShowsFailureInsteadOfSilentlyDisappearing() throws {
        let url = try checkpointURL()
        try Data("broken".utf8).write(to: url)
        XCTAssertEqual(USBReceiveProgressStore(fileURL: url).snapshot().stage, .failed)
    }

    private func progress(_ stage: USBReceiveStage, bytes: Int64) -> USBReceiveProgress {
        USBReceiveProgress(stage: stage, deliveryID: nil, fileName: "map.zip",
            currentIndex: 1, totalCount: 1, completedCount: 0, bytesReceived: bytes,
            totalBytes: 100, startedAt: Date(), expiresAt: nil, errorMessage: nil,
            detail: "2/2 · USB 복사 중 · MAP/file.bin")
    }

    private func checkpointURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("progress.json")
    }
}
