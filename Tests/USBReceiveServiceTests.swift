import CryptoKit
import Foundation
import XCTest
@testable import SimpleCameraAutoSender

private final class DirectReceiveConvenienceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransferNotificationEvent] = []
    var values: [TransferNotificationEvent] { lock.withLock { events } }
    func append(_ event: TransferNotificationEvent) { lock.withLock { events.append(event) } }
}

final class USBReceiveServiceTests: XCTestCase {
    func testEmptyInboxDoesNotRequireUSBAccess() async throws {
        let fixture = try makeFixture(
            payload: Data("unused".utf8),
            chunkSize: 4,
            canAccessSecurityScope: false
        )
        await fixture.client.clearInbox()

        do {
            let summary = try await fixture.service.runOnce()
            XCTAssertEqual(summary, USBReceiveSummary(discovered: 0, completed: 0))
        } catch {
            XCTFail("No incoming file or pending ACK needs USB access: \(error)")
        }
        XCTAssertTrue(fixture.ledger.allCheckpoints().isEmpty)
    }

    func testSuccessfulEmptyPollClearsPreviousDiscoveryFailure() async throws {
        let fixture = try makeFixture(payload: Data("unused".utf8), chunkSize: 4)
        await fixture.client.clearInbox()
        fixture.progressStore.publishFailure("previous connection failure")

        _ = try await fixture.service.runOnce()

        var updates = fixture.progressStore.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .idle)
        XCTAssertNil(latest?.errorMessage)
    }

    func testCurrentListingFailureIsNotClearedAsAnEmptyInbox() async throws {
        let fixture = try makeFixture(payload: Data("unused".utf8), chunkSize: 4)
        await fixture.client.clearInbox()
        await fixture.client.failNextListing()

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("A failed server check must remain an error")
        } catch is URLError {
            // Expected.
        }

        var updates = fixture.progressStore.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .failed)
        XCTAssertTrue(latest?.errorMessage?.contains("네트워크") == true)
    }

    func testEmptyInboxStillRetriesAPendingAcknowledgement() async throws {
        let fixture = try makeFixture(
            payload: Data("verified".utf8), chunkSize: 4, ackFailures: 1
        )
        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected the first ACK to fail")
        } catch StubReceiverError.ackFailed {
            // Expected.
        }
        await fixture.client.clearInbox()

        let summary = try await fixture.service.runOnce()

        XCTAssertEqual(summary.completed, 1)
        XCTAssertNil(fixture.ledger.checkpoint(for: fixture.delivery.deliveryID))
        let acknowledgements = await fixture.client.acknowledgedIDs()
        XCTAssertEqual(acknowledgements, [fixture.delivery.deliveryID])
    }

    func testRepeatedEmptyInboxDoesNotPublishDiscoveryOrCompletion() async throws {
        let fixture = try makeFixture(payload: Data("unused".utf8), chunkSize: 4)
        await fixture.client.clearInbox()
        let updates = fixture.progressStore.updates()

        for _ in 0..<3 {
            let summary = try await fixture.service.runOnce()
            XCTAssertEqual(summary, USBReceiveSummary(discovered: 0, completed: 0))
        }

        fixture.progressStore.publishFailure("end-of-test")
        var stages: [USBReceiveStage] = []
        for await progress in updates {
            if progress.errorMessage == "end-of-test" { break }
            stages.append(progress.stage)
        }
        XCTAssertEqual(stages, [.idle])
        let acknowledgements = await fixture.client.acknowledgedIDs()
        XCTAssertEqual(acknowledgements, [])
    }

    func testEmptyInboxPreservesLocalUSBCopyProgress() async throws {
        let fixture = try makeFixture(payload: Data("unused".utf8), chunkSize: 4)
        await fixture.client.clearInbox()
        let copying = USBReceiveProgress(
            stage: .copyingToUSB,
            deliveryID: UUID(),
            fileName: "local.zip",
            currentIndex: 1,
            totalCount: 1,
            completedCount: 0,
            bytesReceived: 50,
            totalBytes: 100,
            startedAt: Date(),
            expiresAt: nil,
            errorMessage: nil
        )
        fixture.progressStore.publish(copying)

        _ = try await fixture.service.runOnce()

        var updates = fixture.progressStore.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest, copying)
    }

    func testEmptyInboxPreservesLastVerifiedCompletion() async throws {
        let fixture = try makeFixture(payload: Data("verified".utf8), chunkSize: 4)
        _ = try await fixture.service.runOnce()
        await fixture.client.clearInbox()

        _ = try await fixture.service.runOnce()

        var updates = fixture.progressStore.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .completed)
        XCTAssertEqual(latest?.completedCount, 1)
        XCTAssertEqual(latest?.totalCount, 1)
    }

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

    func testExtractDecisionDownloadsPrivatelyCommitsContentsToUSBRootThenAcknowledges() async throws {
        let fixture = try makeFixture(
            payload: validZIPData(),
            fileName: "업무자료.zip",
            chunkSize: 32,
            archiveMode: .extract
        )
        let updates = fixture.progressStore.updates()

        let summary = try await fixture.service.runOnce()

        XCTAssertEqual(summary, USBReceiveSummary(discovered: 1, completed: 1))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("업무자료.zip").path
        ))
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("docs/report.txt")),
            Data("report-data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("root.txt")),
            Data("root-data".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("업무자료").path
        ))
        let acknowledgementRecords = await fixture.client.acknowledgementRecords()
        XCTAssertEqual(acknowledgementRecords.first?.storedName, "")
        XCTAssertNil(fixture.ledger.checkpoint(for: fixture.delivery.deliveryID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagedZIP.path))

        fixture.progressStore.publishFailure("end-of-test")
        var stages: [USBReceiveStage] = []
        for await progress in updates {
            if progress.errorMessage == "end-of-test" { break }
            stages.append(progress.stage)
        }
        XCTAssertTrue(stages.contains(.extracting))
        XCTAssertTrue(stages.contains(.copyingToUSB))
        XCTAssertTrue(stages.contains(.verifying))
        XCTAssertTrue(stages.contains(.acknowledging))
    }

    func testExtractAckFailureRetainsPrivateZIPAndRetriesWithoutDownload() async throws {
        let fixture = try makeFixture(
            payload: validZIPData(),
            fileName: "재시도.zip",
            chunkSize: 32,
            ackFailures: 1,
            archiveMode: .extract
        )

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected first ACK to fail")
        } catch StubReceiverError.ackFailed {
            // Expected.
        }
        let firstRanges = await fixture.client.requestedRanges()
        XCTAssertEqual(
            fixture.ledger.checkpoint(for: fixture.delivery.deliveryID)?.state,
            .ackPending
        )
        XCTAssertEqual(
            fixture.ledger.checkpoint(for: fixture.delivery.deliveryID)?.archiveMode,
            .extract
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stagedZIP.path))
        await fixture.client.clearInbox()

        let summary = try await fixture.service.runOnce()

        XCTAssertEqual(summary.completed, 1)
        let finalRanges = await fixture.client.requestedRanges()
        let finalAckAttempts = await fixture.client.ackAttemptCount()
        XCTAssertEqual(finalRanges, firstRanges)
        XCTAssertEqual(finalAckAttempts, 2)
        XCTAssertNil(fixture.ledger.checkpoint(for: fixture.delivery.deliveryID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagedZIP.path))
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

    func testExistingDifferentRegularFileRequiresOverwriteConfirmation() async throws {
        let fixture = try makeFixture(payload: zipPayload(count: 25), chunkSize: 8)
        let existing = fixture.destination.appendingPathComponent("업무.zip")
        let existingBytes = Data("do-not-overwrite".utf8)
        try existingBytes.write(to: existing)

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected overwrite confirmation")
        } catch let USBZIPReceivePipelineError.overwriteRequired(request) {
            XCTAssertEqual(request.deliveryID, fixture.delivery.deliveryID)
            XCTAssertEqual(request.paths, ["업무.zip"])
        }

        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("업무 (1).zip").path
        ))
    }

    func testApprovedRegularFileOverwriteReplacesExactNameWithoutNumberedCopy() async throws {
        let payload = Data("new-readme".utf8)
        let fixture = try makeFixture(
            payload: payload,
            fileName: "README",
            contentType: "text/plain",
            chunkSize: 4,
            overwriteExisting: true
        )
        let existing = fixture.destination.appendingPathComponent("README")
        let existingBytes = Data("do-not-overwrite".utf8)
        try existingBytes.write(to: existing)

        _ = try await fixture.service.runOnce()

        XCTAssertEqual(try Data(contentsOf: existing), payload)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("README (1)").path
            )
        )
    }

    func testMaximumLengthCollisionAlsoRequiresConfirmation() async throws {
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

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected overwrite confirmation")
        } catch let USBZIPReceivePipelineError.overwriteRequired(request) {
            XCTAssertEqual(request.paths, [requestedName])
        }
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

    func testTemporaryCleanupPreservesRecoveryBackupOriginalBytes() async throws {
        let fixture = try makeFixture(payload: validZIPData(), chunkSize: 8)
        let backup = fixture.destination
            .appendingPathComponent(USBReceiveService.partialDirectoryName)
            .appendingPathComponent("overwrite-\(UUID().uuidString.lowercased()).backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let original = backup.appendingPathComponent("original.txt")
        try Data("irreplaceable-original".utf8).write(to: original)

        let summary = await fixture.service.cleanupTemporaryFiles(
            to: USBBookmarkDestination(
                url: fixture.destination, volumeID: "test-volume",
                displayName: "TEST USB", isStale: false
            )
        )

        XCTAssertEqual(summary.deletedCount, 0)
        XCTAssertEqual(try? Data(contentsOf: original), Data("irreplaceable-original".utf8))
    }

    func testTemporaryCleanupRemovesDirectReceiveWorkButKeepsCompletedUSBFile() async throws {
        let fixture = try makeFixture(payload: validZIPData(), chunkSize: 8)
        try Data("direct-zip-temp".utf8).write(to: fixture.stagedZIP)
        let partialRoot = fixture.destination.appendingPathComponent(
            USBReceiveService.partialDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        let directPartial = partialRoot.appendingPathComponent(
            fixture.delivery.deliveryID.uuidString.lowercased() + ".partial"
        )
        try Data("partial".utf8).write(to: directPartial)
        let completed = fixture.destination.appendingPathComponent("completed.bin")
        try Data("completed".utf8).write(to: completed)

        let summary = await fixture.service.cleanupTemporaryFiles(
            to: USBBookmarkDestination(
                url: fixture.destination,
                volumeID: "test-volume",
                displayName: "TEST USB",
                isStale: false
            )
        )

        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertEqual(summary.deletedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagedZIP.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directPartial.path))
        XCTAssertEqual(try Data(contentsOf: completed), Data("completed".utf8))
    }

    func testProductionDirectZIPPathUsesStoredFileExporterEngine() async throws {
        let fixture = try makeFixture(
            payload: validZIPData(),
            chunkSize: 8,
            archiveMode: .extract,
            useSharedZIPExporter: true
        )

        let result = try await fixture.service.runOnce()

        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("docs/report.txt")),
            Data("report-data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("root.txt")),
            Data("root-data".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("업무.zip").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagedZIP.path))
    }

    func testDirectReceiveInsufficientCapacityPreservesExistingUSBAndDoesNotAcknowledge() async throws {
        let fixture = try makeFixture(payload: Data("replacement".utf8), fileName: "ordinary.pdf",
            contentType: "application/pdf", chunkSize: 4, overwriteExisting: true, capacityQuery: { _ in 1 })
        let final = fixture.destination.appendingPathComponent(fixture.delivery.fileName)
        let existing = Data("existing USB contents".utf8)
        try existing.write(to: final)
        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Known insufficient space must block incoming content")
        } catch {
            let message = IPhoneReceiveErrorMessage.message(error)
            XCTAssertTrue(message.contains("USB"), message)
            XCTAssertTrue(message.contains("MB"), message)
        }
        XCTAssertEqual(try Data(contentsOf: final), existing)
        let acknowledgements = await fixture.client.acknowledgedIDs()
        XCTAssertTrue(acknowledgements.isEmpty)
        XCTAssertEqual(fixture.progressStore.snapshot().capacityCheck?.requiredBytes, 11)
    }

    func testDirectReceiveKnownEnoughCapacityCompletesWithExistingLeaseAndACK() async throws {
        let fixture = try makeFixture(payload: Data("payload".utf8), fileName: "ordinary.pdf",
            contentType: "application/pdf", chunkSize: 4, capacityQuery: { _ in 7 })
        let result = try await fixture.service.runOnce()
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(fixture.delivery.fileName)), Data("payload".utf8))
        let acknowledgements = await fixture.client.acknowledgedIDs()
        XCTAssertEqual(acknowledgements, [fixture.delivery.deliveryID])
    }

    func testDirectReceiveUnknownCapacityDoesNotBecomeInsufficientSpace() async throws {
        let fixture = try makeFixture(payload: Data("payload".utf8), fileName: "ordinary.pdf",
            contentType: "application/pdf", chunkSize: 4, capacityQuery: { _ in nil })
        let result = try await fixture.service.runOnce()
        XCTAssertEqual(result.completed, 1)
        XCTAssertNil(fixture.progressStore.snapshot().capacityCheck?.availableBytes)
        XCTAssertTrue(fixture.progressStore.snapshot().capacityCheck?.displayText.contains("용량 정보 확인 불가") == true)
    }

    func testDirectZIPStagingPreflightBlocksBeforeIncomingContentWhenIPhoneSpaceIsInsufficient() async throws {
        let fixture = try makeFixture(payload: validZIPData(), chunkSize: 4, archiveMode: .extract,
            useSharedZIPExporter: true, capacityQuery: { url in url.lastPathComponent == "usb" ? 1_000_000 : 0 })
        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Compressed ZIP staging also needs its remaining-download capacity check")
        } catch {
            XCTAssertTrue(IPhoneReceiveErrorMessage.message(error).contains("iPhone"))
        }
        let acknowledgements = await fixture.client.acknowledgedIDs()
        XCTAssertTrue(acknowledgements.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("docs/report.txt").path))
    }

    func testDirectZIPSubordinateExportDoesNotNotifyBeforeReceiptAndCompletesExactlyOnce() async throws {
        let fixture = try makeFixture(payload: validZIPData(), chunkSize: 4, archiveMode: .extract, useSharedZIPExporter: true)
        let events = DirectReceiveConvenienceEventRecorder()
        fixture.progressStore.setTransferEventHandler { events.append($0) }
        let result = try await fixture.service.runOnce()
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(events.values.count, 1)
        XCTAssertEqual(events.values.first?.operation, .receive)
        XCTAssertEqual(events.values.first?.outcome, .completed)
        let acknowledgements = await fixture.client.acknowledgedIDs()
        XCTAssertEqual(acknowledgements, [fixture.delivery.deliveryID])
    }

    func testDirectZIPReceiptFailureThenRetryProducesFailureAndSuccessWithoutEarlyExporterCompletion() async throws {
        let fixture = try makeFixture(payload: validZIPData(), chunkSize: 4, ackFailures: 1,
            archiveMode: .extract, useSharedZIPExporter: true)
        let events = DirectReceiveConvenienceEventRecorder()
        fixture.progressStore.setTransferEventHandler { events.append($0) }
        do {
            _ = try await fixture.service.runOnce()
            XCTFail("First receipt must fail in fixture")
        } catch StubReceiverError.ackFailed { }
        XCTAssertEqual(events.values.map(\.outcome), [.failed])
        await fixture.client.clearInbox()
        let result = try await fixture.service.runOnce()
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(events.values.map(\.outcome), [.failed, .completed])
    }

    func testSharedZIPExporterReportsRetainedRecoveryPath() async throws {
        let fileManager = RecoveryFailureFileManager()
        let fixture = try makeFixture(payload: validZIPData(), fileName: "archive.zip", chunkSize: 4,
            archiveMode: .extract, overwriteExisting: true, useSharedZIPExporter: true,
            exportFileManager: fileManager)
        let original = Data("original-data".utf8)
        try original.write(to: fixture.destination.appendingPathComponent("root.txt"))
        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected installation and restoration failure")
        } catch {
            XCTAssertTrue(IPhoneReceiveErrorMessage.message(error).contains(".backup"))
        }
        XCTAssertTrue(fileManager.installFailed)
        XCTAssertTrue(fileManager.rollbackFailed)
        let remaining = (FileManager.default.enumerator(at: fixture.destination, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        XCTAssertTrue(remaining.contains { (try? Data(contentsOf: $0)) == original })
    }

    func testRegularDirectReceiveReportsBackupWhenInstallAndRollbackFail() async throws {
        let fileManager = RecoveryFailureFileManager()
        let fixture = try makeFixture(payload: Data("replacement".utf8), fileName: "root.txt",
            contentType: "text/plain", chunkSize: 4, overwriteExisting: true,
            receiveFileManager: fileManager)
        let original = Data("irreplaceable original".utf8)
        try original.write(to: fixture.destination.appendingPathComponent("root.txt"))

        do {
            _ = try await fixture.service.runOnce()
            XCTFail("Expected installation and restoration failure")
        } catch {
            XCTAssertTrue(error is USBCommitRecoveryError, "Both failures must report the retained backup: \(error)")
            XCTAssertTrue(IPhoneReceiveErrorMessage.message(error).contains(".backup"))
        }
        XCTAssertTrue(fileManager.installFailed)
        XCTAssertTrue(fileManager.rollbackFailed)
        let remaining = (FileManager.default.enumerator(at: fixture.destination, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        XCTAssertTrue(remaining.contains { $0.pathExtension == "backup" && (try? Data(contentsOf: $0)) == original })
        let acknowledgements = await fixture.client.acknowledgedIDs()
        XCTAssertTrue(acknowledgements.isEmpty)
    }

    func testInterruptedSharedZIPExportResumesWithoutRewritingVerifiedArchive() async throws {
        let fileManager = InterruptFirstSharedZIPCopyFileManager()
        let payload = validZIPData()
        let chunkSize = Int64(payload.count - 1)
        let fixture = try makeFixture(payload: payload, chunkSize: chunkSize, archiveMode: .extract,
            useSharedZIPExporter: true, exportFileManager: fileManager)
        XCTAssertEqual(Int64(fixture.payload.count) % chunkSize, 1, "The ZIP must have a partial final download chunk")
        let first = Task { try await fixture.service.runOnce() }
        do {
            _ = try await first.value
            XCTFail("Expected interruption during shared USB copying")
        } catch { }
        XCTAssertTrue(fileManager.interrupted)
        XCTAssertEqual(try Data(contentsOf: fixture.stagedZIP), fixture.payload)
        let beforeRanges = await fixture.client.requestedRanges()
        let timestamp = try fixture.stagedZIP.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let extractionCount = fileManager.extractionCount
        fileManager.stagedZIP = fixture.stagedZIP

        let reopenedService = try fixture.reopenService()
        let resumed = try await reopenedService.runOnce()

        XCTAssertEqual(resumed.completed, 1)
        let afterRanges = await fixture.client.requestedRanges()
        XCTAssertEqual(afterRanges, beforeRanges, "A verified ZIP must not request its tail again")
        XCTAssertEqual(fileManager.observedStagedModificationDate, timestamp, "Shared export must see the unchanged verified source")
        XCTAssertEqual(fileManager.extractionCount, extractionCount, "Reuse the existing extracted job")
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent("docs/report.txt")), Data("report-data".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent("root.txt")), Data("root-data".utf8))
    }

    func testInterruptedSharedZIPExportRejectsChangedStagedArchive() async throws {
        let fileManager = InterruptFirstSharedZIPCopyFileManager()
        let payload = validZIPData()
        let fixture = try makeFixture(payload: payload, chunkSize: Int64(payload.count - 1), archiveMode: .extract,
            useSharedZIPExporter: true, exportFileManager: fileManager)
        let first = Task { try await fixture.service.runOnce() }
        do {
            _ = try await first.value
            XCTFail("Expected interruption during shared USB copying")
        } catch { }
        XCTAssertTrue(fileManager.interrupted)
        XCTAssertEqual(try Data(contentsOf: fixture.stagedZIP), fixture.payload)
        let timestamp = try fixture.stagedZIP.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var changed = fixture.payload
        changed[8] ^= 1
        try changed.write(to: fixture.stagedZIP)
        if let timestamp {
            try FileManager.default.setAttributes([.modificationDate: timestamp.addingTimeInterval(10)], ofItemAtPath: fixture.stagedZIP.path)
        }
        let extractionCount = fileManager.extractionCount

        await assertFailure(.shaMismatch, fixture: fixture)

        XCTAssertEqual(fileManager.extractionCount, extractionCount, "Changed staging must never reuse or create an extraction job")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("root.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("docs/report.txt").path))
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
        currentVolumeID: String = "test-volume",
        archiveMode: IPhoneReceiveArchiveMode = .keepArchive,
        overwriteExisting: Bool = false,
        useSharedZIPExporter: Bool = false,
        exportFileManager: FileManager = .default,
        receiveFileManager: FileManager = .default,
        capacityQuery: @escaping StorageCapacityPreflight.Query = { try StorageCapacityPreflight.system($0) }
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
        let ledgerURL = temporaryDirectory().appendingPathComponent("ledger.json")
        let ledger = try USBReceiveLedger(fileURL: ledgerURL)
        let credentials = IPhoneReceiverCredentials(
            identity: IPhoneReceiverIdentity(
                receiverID: UUID(),
                code: "123456",
                deviceName: "테스트 iPhone"
            ),
            secret: "receive-secret"
        )
        let progressStore = USBReceiveProgressStore()
        let zipStagingDirectory = temporaryDirectory()
        let sharedZIPExporter: IPhoneUSBExportService?
        if useSharedZIPExporter {
            sharedZIPExporter = IPhoneUSBExportService(
                deletionStore: try IPhoneUSBDeletionDecisionStore(
                    fileURL: temporaryDirectory().appendingPathComponent("direct-decisions.json")
                ),
                fileManager: exportFileManager,
                startAccessing: { _ in canAccessSecurityScope },
                stopAccessing: { _ in },
                volumeIdentity: { _ in currentVolumeID },
                progressStore: progressStore,
                zipWorkingDirectory: temporaryDirectory(),
                capacityQuery: capacityQuery
            )
        } else {
            sharedZIPExporter = nil
        }
        let makeService: @Sendable (USBReceiveLedger) -> USBReceiveService = { ledger in
            USBReceiveService(
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
                stopAccessing: { _ in },
                fileManager: receiveFileManager,
                progressStore: progressStore,
                receiveDecision: { _, deliveryID in
                    deliveryID == delivery.deliveryID
                        ? IPhoneReceiveDecision(
                            destination: .usb,
                            archiveMode: archiveMode,
                            overwriteExisting: overwriteExisting
                        )
                        : nil
                },
                zipStagingDirectory: zipStagingDirectory,
                zipExporter: sharedZIPExporter,
                capacityQuery: capacityQuery
            )
        }
        let service = makeService(ledger)
        return Fixture(
            client: client,
            ledger: ledger,
            service: service,
            destination: destination,
            delivery: delivery,
            payload: payload,
            progressStore: progressStore,
            stagedZIP: zipStagingDirectory.appendingPathComponent(
                delivery.deliveryID.uuidString.lowercased() + ".zip.partial"
            ),
            reopenService: { makeService(try USBReceiveLedger(fileURL: ledgerURL)) }
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

    private func validZIPData() -> Data {
        Data(base64Encoded:
            "UEsDBBQAAAAIANJIKF03rc1dEwAAAAsAAAAPAAAAZG9jcy9yZXBvcnQudHh0KkotyC8q0U1JLEkEAAAA//8DAFBLAwQUAAAACADSSChd+/k8aREAAAAJAAAACAAAAHJvb3QudHh0KsrPL9FNSSxJBAAAAP//AwBQSwECFAAUAAAACADSSChdN63NXRMAAAALAAAADwAAAAAAAAAAAAAAAAAAAAAAZG9jcy9yZXBvcnQudHh0UEsBAhQAFAAAAAgA0kgoXfv5PGkRAAAACQAAAAgAAAAAAAAAAAAAAAAAQAAAAHJvb3QudHh0UEsFBgAAAAACAAIAcwAAAHcAAAAAAA=="
        )!
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

private final class RecoveryFailureFileManager: FileManager, @unchecked Sendable {
    private(set) var installFailed = false
    private(set) var rollbackFailed = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent == "root.txt",
           !dstURL.pathComponents.contains(USBReceiveService.partialDirectoryName),
           srcURL.pathComponents.contains(where: { $0.hasSuffix(".partial") || $0.hasSuffix(".backup") }) {
            if srcURL.pathComponents.contains(where: { $0.hasSuffix(".backup") }) {
                rollbackFailed = true
            } else {
                installFailed = true
            }
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class InterruptFirstSharedZIPCopyFileManager: FileManager, @unchecked Sendable {
    private(set) var interrupted = false
    var stagedZIP: URL?
    private(set) var observedStagedModificationDate: Date?
    private(set) var extractionCount = 0

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        if path == stagedZIP?.path {
            observedStagedModificationDate = attributes[.modificationDate] as? Date
        }
        return attributes
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.lastPathComponent.hasPrefix("extract-") { extractionCount += 1 }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        if path.contains("export-"), path.contains(".partial/") {
            if !interrupted {
                interrupted = true
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        return created
    }
}

private struct Fixture {
    let client: StubReceiverClient
    let ledger: USBReceiveLedger
    let service: USBReceiveService
    let destination: URL
    let delivery: IPhoneDelivery
    let payload: Data
    let progressStore: USBReceiveProgressStore
    let stagedZIP: URL
    let reopenService: @Sendable () throws -> USBReceiveService
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
    private var inboxIsEmpty = false
    private var listingShouldFail = false

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
        if listingShouldFail {
            listingShouldFail = false
            throw URLError(.notConnectedToInternet)
        }
        return inboxIsEmpty ? [] : [delivery]
    }

    func clearInbox() { inboxIsEmpty = true }
    func failNextListing() { listingShouldFail = true }

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
