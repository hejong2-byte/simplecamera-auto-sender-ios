import CryptoKit
import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBReceiveServiceTests: XCTestCase {
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

    private func makeFixture(
        payload: Data,
        fileName: String = "업무.zip",
        expectedSHA256: String? = nil,
        chunkSize: Int64,
        responseMode: StubReceiverClient.ResponseMode = .partial
    ) throws -> Fixture {
        let destination = temporaryDirectory()
        let delivery = IPhoneDelivery(
            deliveryID: UUID(),
            fileName: fileName,
            contentType: "application/zip",
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
            responseMode: responseMode
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
                    isStale: false
                )
            },
            chunkSize: chunkSize
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

    init(delivery: IPhoneDelivery, payload: Data, responseMode: ResponseMode) {
        self.delivery = delivery
        self.payload = payload
        self.responseMode = responseMode
    }

    func list(receiverID: UUID, receiveSecret: String) async throws -> [IPhoneDelivery] {
        [delivery]
    }

    func lease(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String
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
        sha256: String
    ) async throws {
        acknowledgements.append(deliveryID)
    }

    func requestedRanges() -> [ClosedRange<Int64>] { ranges }
    func acknowledgedIDs() -> [UUID] { acknowledgements }
}
