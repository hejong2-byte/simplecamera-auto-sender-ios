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

    func testZIPSignatureAndBoundedContentRangeValidation() throws {
        XCTAssertTrue(USBReceiveIntegrity.isZIPSignature(Data([0x50, 0x4b, 0x03, 0x04])))
        XCTAssertFalse(USBReceiveIntegrity.isZIPSignature(Data([0, 1, 2, 3])))
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

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
