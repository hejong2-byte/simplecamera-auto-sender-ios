import CryptoKit
import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBReceiveServiceTests: XCTestCase {
    func testZeroByteFileSkipsRangesAndAcknowledgesUSBStoredName() async throws {
        let fixture = try makeFixture(
            payload: Data(),
            fileName: "empty.bin",
            contentType: "application/octet-stream",
            chunkSize: 4
        )

        let summary = try await fixture.service.runOnce()
        let requestedRanges = await fixture.client.requestedRanges()
        let acknowledgementRecords = await fixture.client.acknowledgementRecords()

        XCTAssertEqual(summary, USBReceiveSummary(discovered: 1, completed: 1))
        XCTAssertEqual(requestedRanges, [])
        XCTAssertEqual(
            acknowledgementRecords,
            [DirectUSBAck(
                deliveryID: fixture.delivery.deliveryID,
                storageLocation: .usb,
                storedName: "empty.bin"
            )]
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("empty.bin")),
            Data()
        )
    }

    func testRunOnceUsesBoundedRangesAndAcknowledgesVerifiedZIP() async throws {
        XCTAssertEqual(USBReceiveService.defaultChunkSize, 8 * 1_024 * 1_024)
        let fixture = try makeFixture(payload: zipPayload(count: 25), chunkSize: 8)

        let summary = try await fixture.service.runOnce()
        let requestedRanges = await fixture.client.requestedRanges()
        let acknowledgedIDs = await fixture.client.acknowledgedIDs()

        XCTAssertEqual(summary.discovered, 1)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(
            requestedRanges,
            [0...7, 8...15, 16...23, 24...24]
        )
        XCTAssertEqual(acknowledgedIDs, [fixture.delivery.deliveryID])
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("업무.zip")),
            fixture.payload
        )
        XCTAssertNil(fixture.ledger.checkpoint(for: fixture.delivery.deliveryID))
    }

    func testRunOnceSavesAndAcknowledgesVerifiedNonZIPFile() async throws {
        let payload = Data("original-hwp-data".utf8)
        let fixture = try makeFixture(
            payload: payload,
            fileName: "결재문서.hwp",
            contentType: "application/x-hwp",
            chunkSize: 5
        )

        let summary = try await fixture.service.runOnce()
        let acknowledgedIDs = await fixture.client.acknowledgedIDs()

        XCTAssertEqual(summary.discovered, 1)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(acknowledgedIDs, [fixture.delivery.deliveryID])
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("결재문서.hwp")),
            payload
        )
        XCTAssertNil(fixture.ledger.checkpoint(for: fixture.delivery.deliveryID))
    }

    func testRunOnceTruncatesUnconfirmedTailAndResumesFromSafeBoundary() async throws {
        let payload = zipPayload(count: 25)
        let fixture = try makeFixture(payload: payload, fileName: "resume.zip", chunkSize: 8)
        let partialDirectory = fixture.destination.appendingPathComponent(
            USBReceiveService.partialDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: partialDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = partialDirectory.appendingPathComponent(
            fixture.delivery.deliveryID.uuidString.lowercased() + ".partial"
        )
        try payload.prefix(18).write(to: partialURL)
        try fixture.ledger.save(
            USBReceiveCheckpoint(
                deliveryID: fixture.delivery.deliveryID,
                fileName: "resume.zip",
                sha256: fixture.delivery.sha256,
                totalBytes: Int64(payload.count),
                confirmedOffset: 24,
                destinationVolumeID: "test-volume",
                finalFileName: "resume.zip",
                state: .downloading
            )
        )

        _ = try await fixture.service.runOnce()
        let requestedRanges = await fixture.client.requestedRanges()

        XCTAssertEqual(requestedRanges.first, 16...23)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("resume.zip")),
            payload
        )
    }

    func testHashMismatchNeverMovesOrAcknowledgesFile() async throws {
        let fixture = try makeFixture(
            payload: zipPayload(count: 25),
            expectedSHA256: String(repeating: "a", count: 64),
            chunkSize: 8
        )

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected SHA verification to fail")
        } catch USBReceiveServiceError.shaMismatch {
            // Expected.
        }

        let acknowledgedIDs = await fixture.client.acknowledgedIDs()
        XCTAssertEqual(acknowledgedIDs, [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("업무.zip").path
            )
        )
    }

    func testExistingDifferentFileGetsNumberedNameWithoutOverwrite() async throws {
        let fixture = try makeFixture(payload: zipPayload(count: 25), chunkSize: 8)
        let existing = fixture.destination.appendingPathComponent("업무.zip")
        let existingBytes = Data("do-not-overwrite".utf8)
        try existingBytes.write(to: existing)

        _ = try await fixture.service.runOnce()

        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("업무 (1).zip")),
            fixture.payload
        )
    }

    func testExtensionlessFileCollisionUsesNumberedNameWithoutTrailingDot() async throws {
        let payload = Data("new-readme".utf8)
        let fixture = try makeFixture(
            payload: payload,
            fileName: "README",
            contentType: "text/plain",
            chunkSize: 4
        )
        let existing = fixture.destination.appendingPathComponent("README")
        let existingBytes = Data("do-not-overwrite".utf8)
        try existingBytes.write(to: existing)

        _ = try await fixture.service.runOnce()

        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("README (1)")),
            payload
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("README (1).").path
            )
        )
    }

    func testMaximumLengthCollisionPreservesExtensionWithinUTF8Limit() async throws {
        let requestedName = String(repeating: "a", count: 236) + ".zip"
        let payload = zipPayload(count: 12)
        let fixture = try makeFixture(
            payload: payload,
            fileName: requestedName,
            chunkSize: 4
        )
        try Data("existing".utf8).write(
            to: fixture.destination.appendingPathComponent(requestedName)
        )

        _ = try await fixture.service.runOnce()

        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.path
        ).filter { !$0.hasPrefix(".") && $0 != requestedName }
        let storedName = try XCTUnwrap(names.first)
        XCTAssertLessThanOrEqual(storedName.lengthOfBytes(using: .utf8), 240)
        XCTAssertEqual((storedName as NSString).pathExtension, "zip")
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent(storedName)),
            payload
        )
    }

    func testStaleDestinationFailsWithoutAcknowledgement() async throws {
        let fixture = try makeFixture(
            payload: Data("file".utf8),
            chunkSize: 4,
            destinationIsStale: true
        )

        await assertFailure(.staleDestination, fixture: fixture)
    }

    func testSecurityScopeFailureFailsWithoutAcknowledgement() async throws {
        let fixture = try makeFixture(
            payload: Data("file".utf8),
            chunkSize: 4,
            canAccessSecurityScope: false
        )

        await assertFailure(.destinationNotWritable, fixture: fixture)
    }

    func testDifferentVolumeFailsWithoutAcknowledgement() async throws {
        let fixture = try makeFixture(
            payload: Data("file".utf8),
            chunkSize: 4,
            currentVolumeID: "another-volume"
        )

        await assertFailure(.destinationChanged, fixture: fixture)
    }

    func testMissingDestinationDirectoryFailsWithoutAcknowledgement() async throws {
        let fixture = try makeFixture(payload: Data("file".utf8), chunkSize: 4)
        try FileManager.default.removeItem(at: fixture.destination)
        try Data("not-a-directory".utf8).write(to: fixture.destination)

        await assertFailure(.destinationNotWritable, fixture: fixture)
    }

    func testDotDotFileNameIsRejectedWithoutAcknowledgement() async throws {
        let fixture = try makeFixture(
            payload: Data("unsafe".utf8),
            fileName: "..",
            contentType: "application/octet-stream",
            chunkSize: 4
        )

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected unsafe file metadata to fail")
        } catch USBReceiveServiceError.invalidFileMetadata {
            // Expected.
        }

        let acknowledgedIDs = await fixture.client.acknowledgedIDs()
        XCTAssertEqual(acknowledgedIDs, [])
    }

    func testUnexpectedFullResponseResetsPartialAndDoesNotAck() async throws {
        let fixture = try makeFixture(
            payload: zipPayload(count: 25),
            chunkSize: 8,
            responseMode: .fullResponse
        )

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected a bounded Range response error")
        } catch USBReceiveServiceError.unexpectedRangeStatus(200) {
            // Expected.
        }

        let acknowledgedIDs = await fixture.client.acknowledgedIDs()
        XCTAssertEqual(acknowledgedIDs, [])
    }

    func testAckFailureRetriesAckWithoutDownloadingFileAgain() async throws {
        let fixture = try makeFixture(
            payload: zipPayload(count: 25),
            chunkSize: 8,
            ackFailures: 1
        )

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected the first ACK to fail")
        } catch StubReceiverError.ackFailed {
            // Expected.
        }
        let firstRanges = await fixture.client.requestedRanges()
        XCTAssertEqual(
            fixture.ledger.checkpoint(for: fixture.delivery.deliveryID)?.state,
            .ackPending
        )

        _ = try await fixture.service.runOnce()
        let ackAttempts = await fixture.client.ackAttemptCount()
        let secondRanges = await fixture.client.requestedRanges()

        XCTAssertEqual(ackAttempts, 2)
        XCTAssertEqual(secondRanges, firstRanges)
        XCTAssertNil(fixture.ledger.checkpoint(for: fixture.delivery.deliveryID))
    }

    private func makeFixture(
        payload: Data,
        fileName: String = "업무.zip",
        contentType: String = "application/zip",
        expectedSHA256: String? = nil,
        chunkSize: Int64,
        responseMode: StubReceiverClient.ResponseMode = .partial,
        ackFailures: Int = 0,
        destinationIsStale: Bool = false,
        canAccessSecurityScope: Bool = true,
        currentVolumeID: String = "test-volume"
    ) throws -> Fixture {
        let destination = temporaryDirectory()
        let delivery = IPhoneDelivery(
            deliveryID: UUID(),
            fileName: fileName,
            contentType: contentType,
            size: Int64(payload.count),
            sha256: expectedSHA256 ?? sha256(payload),
            state: .available,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(86_400),
            deliveredAt: nil
        )
        let client = StubReceiverClient(
            delivery: delivery,
            payload: payload,
            responseMode: responseMode,
            ackFailures: ackFailures
        )
        let ledger = try USBReceiveLedger(
            fileURL: temporaryDirectory().appendingPathComponent("ledger.json")
        )
        let credentials = IPhoneReceiverCredentials(
            identity: IPhoneReceiverIdentity(
                receiverID: UUID(),
                code: "123456",
                deviceName: "테스트 iPhone"
            ),
            secret: "receive-secret"
        )
        let service = USBReceiveService(
            client: client,
            ledger: ledger,
            credentials: { credentials },
            destination: {
                USBBookmarkDestination(
                    url: destination,
                    volumeID: "test-volume",
                    displayName: "TEST USB",
                    isStale: destinationIsStale
                )
            },
            chunkSize: chunkSize,
            volumeIdentity: { _ in currentVolumeID },
            startAccessing: { _ in canAccessSecurityScope },
            stopAccessing: { _ in }
        )
        return Fixture(
            client: client,
            ledger: ledger,
            service: service,
            destination: destination,
            delivery: delivery,
            payload: payload
        )
    }

    private func assertFailure(
        _ expected: USBReceiveServiceError,
        fixture: Fixture
    ) async {
        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected \(expected)")
        } catch let error as USBReceiveServiceError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let acknowledgedIDs = await fixture.client.acknowledgedIDs()
        XCTAssertEqual(acknowledgedIDs, [])
    }

    private func zipPayload(count: Int) -> Data {
        precondition(count >= 4)
        return Data([0x50, 0x4b, 0x03, 0x04])
            + Data(repeating: 0x5a, count: count - 4)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private struct Fixture {
    let client: StubReceiverClient
    let ledger: USBReceiveLedger
    let service: USBReceiveService
    let destination: URL
    let delivery: IPhoneDelivery
    let payload: Data
}

private actor StubReceiverClient: IPhoneReceiverServing {
    enum ResponseMode: Sendable {
        case partial
        case fullResponse
    }

    private let delivery: IPhoneDelivery
    private let payload: Data
    private let responseMode: ResponseMode
    private var ranges: [ClosedRange<Int64>] = []
    private var acknowledgements: [UUID] = []
    private var acknowledgementDetails: [DirectUSBAck] = []
    private var remainingAckFailures: Int
    private var ackAttempts = 0

    init(
        delivery: IPhoneDelivery,
        payload: Data,
        responseMode: ResponseMode,
        ackFailures: Int
    ) {
        self.delivery = delivery
        self.payload = payload
        self.responseMode = responseMode
        remainingAckFailures = ackFailures
    }

    func list(receiverID: UUID, receiveSecret: String) async throws -> [IPhoneDelivery] {
        [delivery]
    }

    func lease(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String,
        mode: IPhoneReceiveLeaseMode
    ) async throws -> IPhoneDelivery {
        delivery
    }

    func range(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String,
        start: Int64,
        end: Int64
    ) async throws -> IPhoneReceiverRangeChunk {
        ranges.append(start...end)
        switch responseMode {
        case .partial:
            let bytes = payload[Int(start)...Int(end)]
            return IPhoneReceiverRangeChunk(
                data: Data(bytes),
                statusCode: 206,
                contentRange: "bytes \(start)-\(end)/\(payload.count)",
                contentLength: end - start + 1
            )
        case .fullResponse:
            return IPhoneReceiverRangeChunk(
                data: payload,
                statusCode: 200,
                contentRange: nil,
                contentLength: Int64(payload.count)
            )
        }
    }

    func acknowledge(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String,
        sha256: String,
        storageLocation: IPhoneStorageLocation,
        storedName: String
    ) async throws {
        ackAttempts += 1
        if remainingAckFailures > 0 {
            remainingAckFailures -= 1
            throw StubReceiverError.ackFailed
        }
        acknowledgements.append(deliveryID)
        acknowledgementDetails.append(DirectUSBAck(
            deliveryID: deliveryID,
            storageLocation: storageLocation,
            storedName: storedName
        ))
    }

    func requestedRanges() -> [ClosedRange<Int64>] { ranges }
    func acknowledgedIDs() -> [UUID] { acknowledgements }
    func ackAttemptCount() -> Int { ackAttempts }
    func acknowledgementRecords() -> [DirectUSBAck] { acknowledgementDetails }
}

private struct DirectUSBAck: Equatable, Sendable {
    let deliveryID: UUID
    let storageLocation: IPhoneStorageLocation
    let storedName: String
}

private enum StubReceiverError: Error {
    case ackFailed
}
