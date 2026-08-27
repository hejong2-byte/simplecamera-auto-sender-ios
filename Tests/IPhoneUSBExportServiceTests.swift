import CryptoKit
import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneUSBExportServiceTests: XCTestCase {
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
    }

    func testCapacityFailureDoesNotCreateDecisionOrDeleteSource() async throws {
        let context = try makeContext(availableCapacity: { _ in 0 })
        let file = try makeStoredFile(
            name: "large.mov",
            data: Data(repeating: 1, count: 16),
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(summary.failed.map(\.sourceID), [file.id])
        XCTAssertEqual(context.deletionStore.pending(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
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
        availableCapacity: @escaping @Sendable (URL) throws -> Int64? = { _ in Int64.max },
        volumeIdentity: @escaping @Sendable (URL) throws -> String? = { _ in "volume-1" }
    ) throws -> ExportContext {
        let root = temporaryDirectory()
        let sourceDirectory = root.appendingPathComponent("received", isDirectory: true)
        let usbDirectory = root.appendingPathComponent("usb", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usbDirectory, withIntermediateDirectories: true)
        let deletionStore = try IPhoneUSBDeletionDecisionStore(
            fileURL: root.appendingPathComponent("decisions.json")
        )
        let service = IPhoneUSBExportService(
            deletionStore: deletionStore,
            startAccessing: { _ in true },
            stopAccessing: { _ in },
            volumeIdentity: volumeIdentity,
            availableCapacity: availableCapacity,
            now: { Date(timeIntervalSince1970: 456) }
        )
        return ExportContext(
            sourceDirectory: sourceDirectory,
            usbDirectory: usbDirectory,
            destination: USBBookmarkDestination(
                url: usbDirectory,
                volumeID: "volume-1",
                displayName: "TEST USB",
                isStale: false
            ),
            deletionStore: deletionStore,
            service: service
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
