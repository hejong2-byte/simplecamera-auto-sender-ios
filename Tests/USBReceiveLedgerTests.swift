import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBReceiveLedgerTests: XCTestCase {
    func testCheckpointRoundTripAndSafeChunkBoundaryRecovery() throws {
        let fileURL = temporaryDirectory()
            .appendingPathComponent("usb-receive-ledger.json")
        let ledger = try USBReceiveLedger(fileURL: fileURL)
        let deliveryID = UUID()
        let checkpoint = USBReceiveCheckpoint(
            deliveryID: deliveryID,
            fileName: "업무자료.zip",
            sha256: String(repeating: "a", count: 64),
            totalBytes: 40,
            confirmedOffset: 24,
            destinationVolumeID: "usb-volume",
            finalFileName: "업무자료.zip",
            state: .downloading
        )

        try ledger.save(checkpoint)
        let reopened = try USBReceiveLedger(fileURL: fileURL)

        XCTAssertEqual(reopened.checkpoint(for: deliveryID), checkpoint)
        XCTAssertEqual(
            USBReceiveCheckpoint.safeResumeOffset(
                actualLength: 30,
                confirmedOffset: 24,
                chunkSize: 8
            ),
            24
        )
        XCTAssertEqual(
            USBReceiveCheckpoint.safeResumeOffset(
                actualLength: 18,
                confirmedOffset: 24,
                chunkSize: 8
            ),
            16
        )
    }

    func testBoundedContentRangeValidation() throws {
        XCTAssertNoThrow(
            try USBReceiveIntegrity.validateRange(
                statusCode: 206,
                contentRange: "bytes 8-15/40",
                contentLength: 8,
                expectedStart: 8,
                expectedEnd: 15,
                totalBytes: 40
            )
        )
        XCTAssertThrowsError(
            try USBReceiveIntegrity.validateRange(
                statusCode: 206,
                contentRange: "bytes 9-15/40",
                contentLength: 7,
                expectedStart: 8,
                expectedEnd: 15,
                totalBytes: 40
            )
        )
    }

    func testArchiveModeRoundTripsAndLegacyCheckpointDefaultsToKeepArchive() throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("ledger.json")
        let ledger = try USBReceiveLedger(fileURL: fileURL)
        let checkpoint = USBReceiveCheckpoint(
            deliveryID: UUID(),
            fileName: "업무자료.zip",
            sha256: String(repeating: "a", count: 64),
            totalBytes: 10,
            confirmedOffset: 10,
            destinationVolumeID: "usb",
            finalFileName: "업무자료",
            state: .ackPending,
            archiveMode: .extract
        )
        try ledger.save(checkpoint)
        XCTAssertEqual(
            try USBReceiveLedger(fileURL: fileURL)
                .checkpoint(for: checkpoint.deliveryID)?.archiveMode,
            .extract
        )

        let legacyURL = directory.appendingPathComponent("legacy.json")
        let legacy = """
        [{"deliveryID":"\(UUID().uuidString)","fileName":"old.zip","sha256":"\(String(repeating: "b", count: 64))","totalBytes":1,"confirmedOffset":0,"destinationVolumeID":"usb","finalFileName":"old.zip","state":"downloading"}]
        """
        try Data(legacy.utf8).write(to: legacyURL)
        XCTAssertEqual(
            try USBReceiveLedger(fileURL: legacyURL).allCheckpoints().first?.archiveMode,
            .keepArchive
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
