import CryptoKit
import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneUSBExportServiceTests: XCTestCase {
    func testVerifiedCompletionShowsCopiedBytesInsteadOfZeroOfZero() async throws {
        let context = try makeContext()
        let payload = Data(repeating: 0x5a, count: 2 * 1_024 * 1_024 + 17)
        let file = try makeStoredFile(
            name: "large-test.zip",
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
        XCTAssertTrue(stages.contains(.verifying))
        XCTAssertEqual(startTimes.count, 1)
    }

    func testPathBackedDestinationWithoutVolumeMetadataCanCopyAndKeepsOriginal() async throws {
        let context = try makeContext(
            volumeIdentity: { _ in nil },
            destinationVolumeID: nil
        )
        let payload = Data("original-local-file".utf8)
        let file = try makeStoredFile(
            name: "local.zip",
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
            name: "cannot-copy.zip",
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
            expectedSHA256: String(repeating: "0", count: 64),
            in: context.sourceDirectory
        )
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
            name: "capacity-report.zip",
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
                name: "keep-original.zip",
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

    private func makeContext(
        fileManager: FileManager = .default,
        volumeIdentity: @escaping @Sendable (URL) throws -> String? = { _ in "volume-1" },
        destinationVolumeID: String? = "volume-1",
        canAccessSecurityScope: Bool = true
    ) throws -> ExportContext {
        let root = temporaryDirectory()
        let sourceDirectory = root.appendingPathComponent("received", isDirectory: true)
        let usbDirectory = root.appendingPathComponent("usb", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usbDirectory, withIntermediateDirectories: true)
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
            now: { Date(timeIntervalSince1970: 456) }
        )
        return ExportContext(
            sourceDirectory: sourceDirectory,
            usbDirectory: usbDirectory,
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
