import CryptoKit
import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneUSBExportServiceTests: XCTestCase {
    func testOptionalVerificationDetectsTamperingWithoutDeletingEitherCopy() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "optional.bin", data: Data("original".utf8), in: context.sourceDirectory)
        let copied = await context.service.export([file], to: context.destination)
        let decision = try XCTUnwrap(copied.verified.first)
        let target = context.usbDirectory.appendingPathComponent(decision.usbStoredName)
        try await context.service.keep(decisionIDs: [decision.id])
        let checked = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertEqual(checked.failed, [])
        XCTAssertEqual(checked.verified.count, 1)
        try Data("tampered".utf8).write(to: target)
        let failed = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertEqual(failed.failed.map(\.error), [.shaMismatch])
        XCTAssertEqual(try Data(contentsOf: target), Data("tampered".utf8))
        XCTAssertEqual(try Data(contentsOf: file.url), Data("original".utf8))
    }

    func testOptionalVerificationReadFailureDoesNotDeleteCopiedFolderOrOriginal() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "read-error.bin", data: Data("original".utf8), in: context.sourceDirectory)
        let copied = await context.service.export([file], to: context.destination)
        let decision = try XCTUnwrap(copied.verified.first)
        let target = context.usbDirectory.appendingPathComponent(decision.usbStoredName)
        // Replace with a directory: the read/type check must fail, without cleanup of user data.
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let result = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testVerificationManifestSurvivesStoreReopenAndKeepOriginalDecision() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "retained.txt", data: Data("data".utf8), in: context.sourceDirectory)
        let copied = await context.service.export([file], to: context.destination)
        let decision = try XCTUnwrap(copied.verified.first)
        try await context.service.keep(decisionIDs: [decision.id])
        let reopened = try IPhoneUSBDeletionDecisionStore(fileURL: context.sourceDirectory.deletingLastPathComponent().appendingPathComponent("decisions.json"))
        XCTAssertTrue(reopened.pending().isEmpty)
        XCTAssertEqual(reopened.copies().first?.copiedFiles?.first?.size, 4)
    }

    func testOptionalVerificationRejectsWrongUSBWithoutTouchingOriginal() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "guard.txt", data: Data("data".utf8), in: context.sourceDirectory)
        _ = await context.service.export([file], to: context.destination)
        let wrong = USBBookmarkDestination(url: context.usbDirectory, volumeID: "other", displayName: "wrong", isStale: false)
        let result = await context.service.verifyCopies([file], to: wrong)
        XCTAssertEqual(result.failed.map(\.error), [.destinationChanged])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testVerifiedCompletionShowsCopiedBytesInsteadOfZeroOfZero() async throws {
        let context = try makeContext()
        let payload = Data(repeating: 0x5a, count: 2 * 1_024 * 1_024 + 17)
        let file = try makeStoredFile(
            name: "large-test.bin",
            data: payload,
            in: context.sourceDirectory
        )
        let updates = context.progressStore.updates()

        let summary = await context.service.export([file], to: context.destination)
        var latest = context.progressStore.updates().makeAsyncIterator()
        let completion = await latest.next()

        XCTAssertEqual(summary.failed, [])
        XCTAssertEqual(completion?.stage, .completed)
        XCTAssertEqual(completion?.completedCount, 1)
        XCTAssertEqual(completion?.bytesReceived, Int64(payload.count))
        XCTAssertEqual(completion?.totalBytes, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: file.url), payload)

        context.progressStore.publishFailure("end-of-test")
        var stages: [USBReceiveStage] = []
        var startTimes: Set<Date> = []
        for await progress in updates {
            if progress.errorMessage == "end-of-test" { break }
            stages.append(progress.stage)
            if let startedAt = progress.startedAt { startTimes.insert(startedAt) }
        }
        XCTAssertTrue(stages.contains(.copyingToUSB))
        XCTAssertFalse(stages.contains(.verifying), "Default copy must finish without rereading the USB for SHA")
        XCTAssertEqual(startTimes.count, 1)
    }

    func testPathBackedDestinationWithoutVolumeMetadataCanCopyAndKeepsOriginal() async throws {
        let context = try makeContext(
            volumeIdentity: { _ in nil },
            destinationVolumeID: nil
        )
        let payload = Data("original-local-file".utf8)
        let file = try makeStoredFile(
            name: "local.bin",
            data: payload,
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.failed, [])
        XCTAssertEqual(summary.verified.map(\.sourceID), [file.id])
        XCTAssertEqual(try Data(contentsOf: file.url), payload)
        if let storedName = summary.verified.first?.usbStoredName {
            XCTAssertEqual(
                try Data(contentsOf: context.usbDirectory.appendingPathComponent(storedName)),
                payload
            )
        }
    }

    func testZIPExportExtractsIntoNamedUSBFolderKeepsOriginalAndCleansWorkingFiles() async throws {
        let context = try makeContext()
        let archiveData = try XCTUnwrap(Data(base64Encoded:
            "UEsDBBQAAAAIANJIKF03rc1dEwAAAAsAAAAPAAAAZG9jcy9yZXBvcnQudHh0KkotyC8q0U1JLEkEAAAA//8DAFBLAwQUAAAACADSSChd+/k8aREAAAAJAAAACAAAAHJvb3QudHh0KsrPL9FNSSxJBAAAAP//AwBQSwECFAAUAAAACADSSChdN63NXRMAAAALAAAADwAAAAAAAAAAAAAAAAAAAAAAZG9jcy9yZXBvcnQudHh0UEsBAhQAFAAAAAgA0kgoXfv5PGkRAAAACQAAAAgAAAAAAAAAAAAAAAAAQAAAAHJvb3QudHh0UEsFBgAAAAACAAIAcwAAAHcAAAAAAA=="
        ))
        let file = try makeStoredFile(
            name: "업무자료.ZIP",
            data: archiveData,
            in: context.sourceDirectory
        )

        let progressUpdates = context.progressStore.updates()
        let summary = await context.service.export([file], to: context.destination)
        context.progressStore.publishFailure("end-zip-progress-test")
        var reported: [USBReceiveProgress] = []
        for await progress in progressUpdates {
            if progress.errorMessage == "end-zip-progress-test" { break }
            reported.append(progress)
        }
        XCTAssertTrue(reported.contains { $0.stage == .extracting && $0.totalBytes > 0 })
        XCTAssertFalse(reported.contains { $0.stage == .verifying || $0.stage == .checkingSource }, "Default ZIP export must not perform full SHA passes")

        XCTAssertEqual(summary.failed, [])
        let decision = try XCTUnwrap(summary.verified.first)
        XCTAssertEqual(decision.sourceID, file.id)
        XCTAssertEqual(decision.usbStoredName, "업무자료")
        XCTAssertEqual(try Data(contentsOf: file.url), archiveData, "The received ZIP must remain unchanged")
        let exportedFolder = context.usbDirectory.appendingPathComponent(decision.usbStoredName)
        XCTAssertEqual(
            try Data(contentsOf: exportedFolder.appendingPathComponent("docs/report.txt")),
            Data("report-data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: exportedFolder.appendingPathComponent("root.txt")),
            Data("root-data".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path),
            [],
            "Temporary extracted files must be removed after verified USB copy"
        )
        let verification = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertTrue(verification.failed.isEmpty)
        XCTAssertEqual(verification.verified.count, 1)
    }

    func testZIPExportCanKeepTheArchiveWithoutExtractingIt() async throws {
        let context = try makeContext()
        let archiveData = Data("stored-zip-byte-for-byte".utf8)
        let file = try makeStoredFile(
            name: "업무자료.zip",
            data: archiveData,
            in: context.sourceDirectory
        )

        let summary = await context.service.export(
            [file],
            to: context.destination,
            archiveMode: .keepArchive
        )

        XCTAssertEqual(summary.failed, [])
        let decision = try XCTUnwrap(summary.verified.first)
        XCTAssertEqual(decision.usbStoredName, "업무자료.zip")
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("업무자료.zip")),
            archiveData
        )
        XCTAssertEqual(try Data(contentsOf: file.url), archiveData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path),
            []
        )
    }

    func testUnsafeZIPPathFailsWithoutLeavingUSBOrWorkingFiles() async throws {
        let context = try makeContext()
        let archiveData = try XCTUnwrap(Data(base64Encoded:
            "UEsDBBQAAAAIANJIKF1Oa16IFQAAAA0AAAAQAAAALi4vLi4vZXNjYXBlLnR4dErJ183LL9FNLU5OLEgFAAAA//8DAFBLAQIUABQAAAAIANJIKF1Oa16IFQAAAA0AAAAQAAAAAAAAAAAAAAAAAAAAAAAuLi8uLi9lc2NhcGUudHh0UEsFBgAAAAABAAEAPgAAAEMAAAAAAA=="
        ))
        let file = try makeStoredFile(
            name: "unsafe.zip",
            data: archiveData,
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(summary.failed.map(\.error), [.unsafeZIPArchive])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.zipWorkingDirectory.deletingLastPathComponent()
                .appendingPathComponent("escape.txt").path
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path), [])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: context.usbDirectory.path)
                .filter { $0 != IPhoneUSBExportService.partialDirectoryName },
            []
        )
    }

    func testCorruptZIPFailsAndCleansTemporaryFilesWithoutDeletingOriginal() async throws {
        let context = try makeContext()
        let archiveData = Data("not-a-zip".utf8)
        let file = try makeStoredFile(
            name: "damaged.zip",
            data: archiveData,
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(summary.failed.map(\.error), [.zipExtractionFailed])
        XCTAssertEqual(try Data(contentsOf: file.url), archiveData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path), [])
    }

    func testMissingVolumeMetadataDoesNotAcceptDifferentSavedIdentity() async throws {
        let context = try makeContext(volumeIdentity: { _ in nil })
        let file = try makeStoredFile(
            name: "keep.txt",
            data: Data("keep-original".utf8),
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(summary.failed.map(\.error), [.destinationChanged])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(context.deletionStore.pending(), [])
    }

    func testAccessFailureReportsTheActualReasonAndFileName() async throws {
        let context = try makeContext(canAccessSecurityScope: false)
        let file = try makeStoredFile(
            name: "cannot-copy.bin",
            data: Data("keep-original".utf8),
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)
        var updates = context.progressStore.updates().makeAsyncIterator()
        let progress = await updates.next()

        XCTAssertEqual(summary.failed.map(\.error), [.destinationAccessDenied])
        XCTAssertEqual(progress?.stage, .failed)
        XCTAssertEqual(progress?.fileName, file.name)
        XCTAssertTrue(progress?.errorMessage?.contains("권한") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testUnexpectedFileSystemFailurePreservesDiagnosticCode() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(
            name: "removed-before-copy.txt",
            data: Data("temporary-test-file".utf8),
            in: context.sourceDirectory
        )
        try FileManager.default.removeItem(at: file.url)

        let summary = await context.service.export([file], to: context.destination)
        var updates = context.progressStore.updates().makeAsyncIterator()
        let progress = await updates.next()

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(progress?.stage, .failed)
        XCTAssertTrue(progress?.errorMessage?.contains("NSCocoaErrorDomain") == true)
        XCTAssertEqual(context.deletionStore.pending(), [])
    }

    func testExportVerifiesGoodFileRecordsPartialFailureAndLeavesSources() async throws {
        let context = try makeContext()
        let good = try makeStoredFile(
            name: "보고서.hwp",
            data: Data("verified-data".utf8),
            in: context.sourceDirectory
        )
        let bad = try makeStoredFile(
            name: "변경됨.pdf",
            data: Data("changed-data".utf8),
            in: context.sourceDirectory
        )
        try Data("changed-size-after-selection".utf8).write(to: bad.url)
        try Data("existing".utf8).write(
            to: context.usbDirectory.appendingPathComponent(good.name)
        )

        let summary = await context.service.export(
            [good, bad],
            to: context.destination
        )

        XCTAssertEqual(summary.verified.map(\.sourceID), [good.id])
        XCTAssertEqual(summary.failed.map(\.sourceID), [bad.id])
        XCTAssertEqual(context.deletionStore.pending().map(\.sourceID), [good.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.url.path))
        let storedName = try XCTUnwrap(summary.verified.first?.usbStoredName)
        XCTAssertNotEqual(storedName, good.name)
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent(storedName)),
            Data("verified-data".utf8)
        )

        try await context.service.keep(decisionIDs: Set(summary.verified.map(\.id)))
        var updates = context.progressStore.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .failed, "Keeping good originals must not hide a failed copy")
        XCTAssertNotNil(latest?.errorMessage)
    }

    func testReportedZeroCapacityDoesNotBlockVerifiedCopyToWritableUSB() async throws {
        let fileManager = ZeroCapacityUSBFileManager()
        let context = try makeContext(fileManager: fileManager)
        let payload = Data(repeating: 0x5a, count: 1_024 * 1_024 + 31)
        let file = try makeStoredFile(
            name: "capacity-report.bin",
            data: payload,
            in: context.sourceDirectory
        )
        let reported = try fileManager.attributesOfFileSystem(forPath: context.usbDirectory.path)
        XCTAssertEqual((reported[.systemFreeSize] as? NSNumber)?.int64Value, 0)
        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: context.usbDirectory.path
        )
        let actualFree = try XCTUnwrap(attributes[.systemFreeSize] as? NSNumber)
        XCTAssertGreaterThan(actualFree.int64Value, Int64(payload.count))

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.failed, [])
        XCTAssertEqual(summary.verified.map(\.sourceID), [file.id])
        XCTAssertEqual(try Data(contentsOf: file.url), payload)
        if let storedName = summary.verified.first?.usbStoredName {
            XCTAssertEqual(
                try Data(contentsOf: context.usbDirectory.appendingPathComponent(storedName)),
                payload
            )
        }
    }

    func testFileSystemDiskFullErrorsStopCopyAndPreserveFiles() async throws {
        let errors = [
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue),
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
        ]
        for error in errors {
            let context = try makeContext(fileManager: DiskFullUSBFileManager(error: error))
            let payload = Data(repeating: 0x3c, count: 1_024 * 1_024 + 31)
            let file = try makeStoredFile(
                name: "keep-original.bin",
                data: payload,
                in: context.sourceDirectory
            )
            let existingURL = context.usbDirectory.appendingPathComponent("existing.txt")
            let existingData = Data("do-not-touch-existing-usb-files".utf8)
            try existingData.write(to: existingURL)

            let summary = await context.service.export([file], to: context.destination)

            XCTAssertEqual(summary.verified, [])
            XCTAssertEqual(summary.failed.map(\.error), [.insufficientSpace], error.domain)
            XCTAssertTrue(summary.errorMessage?.contains("저장 공간") == true, error.domain)
            XCTAssertTrue(summary.errorMessage?.contains(error.domain) == true)
            XCTAssertTrue(summary.errorMessage?.contains(String(error.code)) == true)
            XCTAssertEqual(context.deletionStore.pending(), [])
            XCTAssertEqual(try Data(contentsOf: file.url), payload)
            XCTAssertEqual(try Data(contentsOf: existingURL), existingData)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: context.usbDirectory.appendingPathComponent(file.name).path
            ))
            let partialDirectory = context.usbDirectory.appendingPathComponent(
                IPhoneUSBExportService.partialDirectoryName
            )
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partialDirectory.path), [])
        }
    }

    func testUSBRemovalStopsLaterFileAndKeepsEverySource() async throws {
        let volume = SequencedVolumeIdentity(values: ["volume-1", "removed"])
        let context = try makeContext(volumeIdentity: { _ in volume.next() })
        let first = try makeStoredFile(
            name: "first.txt",
            data: Data("first".utf8),
            in: context.sourceDirectory
        )
        let second = try makeStoredFile(
            name: "second.txt",
            data: Data("second".utf8),
            in: context.sourceDirectory
        )

        let summary = await context.service.export([first, second], to: context.destination)

        XCTAssertEqual(summary.verified.map(\.sourceID), [first.id])
        XCTAssertEqual(summary.failed.map(\.sourceID), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testKeepAndDeleteDecisionsRecheckSourceBeforeDeletion() async throws {
        let context = try makeContext()
        let keepFile = try makeStoredFile(
            name: "keep.txt",
            data: Data("keep".utf8),
            in: context.sourceDirectory
        )
        let deleteFile = try makeStoredFile(
            name: "delete.txt",
            data: Data("delete".utf8),
            in: context.sourceDirectory
        )
        let changedFile = try makeStoredFile(
            name: "changed.txt",
            data: Data("original".utf8),
            in: context.sourceDirectory
        )
        let summary = await context.service.export(
            [keepFile, deleteFile, changedFile],
            to: context.destination
        )
        let decisions = Dictionary(
            uniqueKeysWithValues: summary.verified.map { ($0.sourceID, $0) }
        )

        try await context.service.keep(
            decisionIDs: [try XCTUnwrap(decisions[keepFile.id]?.id)]
        )
        try Data("mutated".utf8).write(to: changedFile.url, options: .atomic)
        let deletion = await context.service.delete(decisionIDs: [
            try XCTUnwrap(decisions[deleteFile.id]?.id),
            try XCTUnwrap(decisions[changedFile.id]?.id)
        ])

        XCTAssertEqual(deletion.deletedSourceIDs, [deleteFile.id])
        XCTAssertEqual(deletion.failed.map(\.sourceID), [changedFile.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepFile.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleteFile.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: changedFile.url.path))
        XCTAssertEqual(context.deletionStore.pending().map(\.sourceID), [changedFile.id])
    }

    func testDeletionDecisionsSurviveStoreReopen() async throws {
        let stateURL = temporaryDirectory().appendingPathComponent("decisions.json")
        let store = try IPhoneUSBDeletionDecisionStore(fileURL: stateURL)
        let decision = IPhoneUSBDeletionDecision(
            id: UUID(),
            sourceID: "source",
            sourceURL: URL(fileURLWithPath: "/tmp/source"),
            sourceSize: 0,
            sourceSHA256: sha256(Data()),
            usbStoredName: "empty.bin",
            verifiedAt: Date(timeIntervalSince1970: 123)
        )

        try store.save(decision)
        let reopened = try IPhoneUSBDeletionDecisionStore(fileURL: stateURL)

        XCTAssertEqual(reopened.pending(), [decision])
    }

    func testLegacyDeletionStateWithoutOptionalManifestStillLoads() throws {
        let stateURL = temporaryDirectory().appendingPathComponent("legacy.json")
        let legacy = """
        {"version":1,"decisions":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","sourceID":"old","sourceURL":"file:///tmp/old.zip","sourceSize":8,"sourceSHA256":"abc","usbStoredName":"old.zip","verifiedAt":123}]}
        """
        try Data(legacy.utf8).write(to: stateURL)
        let reopened = try IPhoneUSBDeletionDecisionStore(fileURL: stateURL)
        XCTAssertEqual(reopened.pending().count, 1)
        XCTAssertNil(reopened.pending().first?.copiedFiles)
        XCTAssertTrue(reopened.copies().isEmpty)
    }

    private func makeContext(
        fileManager: FileManager = .default,
        volumeIdentity: @escaping @Sendable (URL) throws -> String? = { _ in "volume-1" },
        destinationVolumeID: String? = "volume-1",
        canAccessSecurityScope: Bool = true
    ) throws -> ExportContext {
        let root = temporaryDirectory()
        let sourceDirectory = root.appendingPathComponent("received", isDirectory: true)
        let usbDirectory = root.appendingPathComponent("usb", isDirectory: true)
        let zipWorkingDirectory = root.appendingPathComponent("zip-work", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usbDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zipWorkingDirectory, withIntermediateDirectories: true)
        let deletionStore = try IPhoneUSBDeletionDecisionStore(
            fileURL: root.appendingPathComponent("decisions.json")
        )
        let progressStore = USBReceiveProgressStore()
        let service = IPhoneUSBExportService(
            deletionStore: deletionStore,
            fileManager: fileManager,
            startAccessing: { _ in canAccessSecurityScope },
            stopAccessing: { _ in },
            volumeIdentity: volumeIdentity,
            progressStore: progressStore,
            zipWorkingDirectory: zipWorkingDirectory,
            now: { Date(timeIntervalSince1970: 456) }
        )
        return ExportContext(
            sourceDirectory: sourceDirectory,
            usbDirectory: usbDirectory,
            zipWorkingDirectory: zipWorkingDirectory,
            destination: USBBookmarkDestination(
                url: usbDirectory,
                volumeID: destinationVolumeID ?? usbDirectory.path,
                displayName: "TEST USB",
                isStale: false
            ),
            deletionStore: deletionStore,
            service: service,
            progressStore: progressStore
        )
    }

    private func makeStoredFile(
        name: String,
        data: Data,
        expectedSHA256: String? = nil,
        in directory: URL
    ) throws -> IPhoneStoredFile {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        let record = IPhoneReceivedFileRecord(
            deliveryID: UUID(),
            originalName: name,
            storedName: name,
            size: Int64(data.count),
            sha256: expectedSHA256 ?? sha256(data),
            receivedAt: Date(timeIntervalSince1970: 100)
        )
        return IPhoneStoredFile(
            id: url.standardizedFileURL.path,
            url: url,
            name: name,
            size: Int64(data.count),
            modifiedAt: Date(timeIntervalSince1970: 100),
            receivedRecord: record
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private struct ExportContext {
    let sourceDirectory: URL
    let usbDirectory: URL
    let zipWorkingDirectory: URL
    let destination: USBBookmarkDestination
    let deletionStore: IPhoneUSBDeletionDecisionStore
    let service: IPhoneUSBExportService
    let progressStore: USBReceiveProgressStore
}

private final class ZeroCapacityUSBFileManager: FileManager, @unchecked Sendable {
    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        [.systemFreeSize: NSNumber(value: 0)]
    }
}

private final class DiskFullUSBFileManager: FileManager, @unchecked Sendable {
    private let writeError: NSError

    init(error: NSError) {
        self.writeError = error
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.pathExtension == "partial" {
            throw writeError
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class SequencedVolumeIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(values: [String]) { self.values = values }

    func next() -> String? {
        lock.withLock {
            guard !values.isEmpty else { return nil }
            return values.removeFirst()
        }
    }
}
