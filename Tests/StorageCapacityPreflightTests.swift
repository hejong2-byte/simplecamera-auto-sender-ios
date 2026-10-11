import Foundation
import XCTest
import ZIPFoundation
@testable import SimpleCameraAutoSender

final class StorageCapacityPreflightTests: XCTestCase {
    func testUnavailableCapacityURLDoesNotClimbIntoAnotherVolume() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("removed-provider/usb")
        XCTAssertNil(try StorageCapacityPreflight.system(missing))
    }

    func testOldProgressCheckpointDecodesWithoutCapacityAndNewExportClearsPreviousCheck() throws {
        let old = """
        {"stage":"completed","destination":"usb","currentIndex":1,"totalCount":1,"completedCount":1,"bytesReceived":10,"totalBytes":10}
        """
        let restored = try JSONDecoder().decode(USBReceiveProgress.self, from: Data(old.utf8))
        XCTAssertNil(restored.capacityCheck)
        let store = USBReceiveProgressStore()
        store.publish(USBReceiveProgress(stage: .completed, deliveryID: nil, fileName: "old.pdf", currentIndex: 1,
            totalCount: 1, completedCount: 1, bytesReceived: 10, totalBytes: 10, startedAt: nil, expiresAt: nil,
            errorMessage: nil, capacityCheck: StorageCapacityCheck(requiredBytes: 10, availableBytes: 20, destination: .usb)))
        store.beginExport(fileName: "new.pdf", totalCount: 1)
        XCTAssertNil(store.snapshot().capacityCheck, "A new job must not show the old device's capacity")
    }

    func testKnownEnoughCapacityCopiesOriginalAndDisplaysRequiredAvailableBytes() async throws {
        let context = try makeContext(capacity: { _ in 20 })
        let file = try storedFile("문서.pdf", data: Data("1234567890".utf8), in: context.source)
        let result = await context.service.export([file], to: context.destination, archiveMode: .keepArchive)
        XCTAssertTrue(result.failed.isEmpty, result.errorMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: context.usb.appendingPathComponent(file.name)), Data("1234567890".utf8))
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 10)
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.availableBytes, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testInsufficientCapacityLeavesOriginalAndExistingDestinationUnchanged() async throws {
        let context = try makeContext(capacity: { _ in 1 })
        let bytes = Data("replacement contents".utf8)
        let file = try storedFile("original.pdf", data: bytes, in: context.source)
        let destination = context.usb.appendingPathComponent(file.name)
        let existing = Data("old USB original".utf8)
        try existing.write(to: destination)
        let result = await context.service.export([file], to: context.destination, archiveMode: .keepArchive, overwriteExisting: true)
        XCTAssertEqual(result.failed.first?.error, .insufficientSpace)
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertTrue(result.errorMessage?.contains("USB") == true)
        XCTAssertTrue(result.errorMessage?.contains("필요") == true)
        XCTAssertTrue(result.errorMessage?.contains("사용 가능") == true)
        XCTAssertTrue(result.errorMessage?.contains("MB") == true)
        XCTAssertTrue(context.decisions.pending().isEmpty)
    }

    func testUnknownCapacityAllowsExistingWriteAndSizeChecks() async throws {
        let context = try makeContext(capacity: { _ in nil })
        let file = try storedFile("unknown.bin", data: Data("payload".utf8), in: context.source)
        let result = await context.service.export([file], to: context.destination, archiveMode: .keepArchive)
        XCTAssertTrue(result.failed.isEmpty, result.errorMessage ?? "")
        XCTAssertNil(context.progress.snapshot().capacityCheck?.availableBytes)
        XCTAssertTrue(context.progress.snapshot().capacityCheck?.displayText.contains("용량 정보 확인 불가") == true)
        XCTAssertEqual(try Data(contentsOf: context.usb.appendingPathComponent(file.name)), Data("payload".utf8))
    }

    func testCapacityQueryErrorIsUnknownAndDoesNotFailCopy() async throws {
        let context = try makeContext(capacity: { _ in throw CocoaError(.fileReadNoPermission) })
        let file = try storedFile("query-error.bin", data: Data("payload".utf8), in: context.source)
        let result = await context.service.export([file], to: context.destination, archiveMode: .keepArchive)
        XCTAssertTrue(result.failed.isEmpty, result.errorMessage ?? "")
        XCTAssertNil(context.progress.snapshot().capacityCheck?.availableBytes)
        XCTAssertEqual(try Data(contentsOf: context.usb.appendingPathComponent(file.name)), Data("payload".utf8))
    }

    func testEmptyFileFitsKnownZeroCapacity() async throws {
        let context = try makeContext(capacity: { _ in 0 })
        let file = try storedFile("empty.bin", data: Data(), in: context.source)
        let result = await context.service.export([file], to: context.destination, archiveMode: .keepArchive)
        XCTAssertTrue(result.failed.isEmpty, result.errorMessage ?? "")
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 0)
        XCTAssertEqual(try Data(contentsOf: context.usb.appendingPathComponent(file.name)), Data())
    }

    func testValidOrdinaryPartialNeedsOnlyRemainingBytes() async throws {
        let context = try makeContext(capacity: { _ in 4 })
        let bytes = Data("1234567890".utf8)
        let file = try storedFile("resume.bin", data: bytes, in: context.source)
        let partial = try partialURL(for: file, context: context)
        try bytes.prefix(6).write(to: partial)
        let result = await context.service.export([file], to: context.destination, archiveMode: .keepArchive, preservePartialOnCancellation: true)
        XCTAssertTrue(result.failed.isEmpty, result.errorMessage ?? "")
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 4)
        XCTAssertEqual(try Data(contentsOf: context.usb.appendingPathComponent(file.name)), bytes)
    }

    func testCapacityShortageRetainsValidOrdinaryPartialForLaterResume() async throws {
        let context = try makeContext(capacity: { _ in 1 })
        let bytes = Data("1234567890".utf8)
        let file = try storedFile("retained-resume.bin", data: bytes, in: context.source)
        let partial = try partialURL(for: file, context: context)
        let existing = bytes.prefix(6)
        try existing.write(to: partial)
        let result = await context.service.export([file], to: context.destination, archiveMode: .keepArchive, preservePartialOnCancellation: true)
        XCTAssertEqual(result.failed.first?.error, .insufficientSpace)
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 4)
        XCTAssertEqual(try Data(contentsOf: partial), existing, "Advisory shortage must not destroy a valid retained partial")
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testRejectedOrdinaryBoundaryAccountsForFullRewriteBeforeWriting() async throws {
        let context = try makeContext(capacity: { _ in 4 })
        let bytes = Data("1234567890".utf8)
        let file = try storedFile("invalid-resume.bin", data: bytes, in: context.source)
        let partial = try partialURL(for: file, context: context)
        try Data("broken".utf8).write(to: partial)
        let result = await context.service.export([file], to: context.destination, archiveMode: .keepArchive, preservePartialOnCancellation: true)
        XCTAssertEqual(result.failed.first?.error, .insufficientSpace)
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usb.appendingPathComponent(file.name).path))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testExpandedZIPSpaceBlocksBeforeExtractionAndUSBWriting() async throws {
        let context = try makeContext(capacity: { url in url.lastPathComponent == "usb" ? 1_000_000 : 16_384 })
        let file = try zipFile(context: context, expandedBytes: 131_072)
        XCTAssertLessThan(file.size, 16_384, "Fixture must be compressed small and expanded large")
        let original = try Data(contentsOf: file.url)
        let result = await context.service.export([file], to: context.destination)
        XCTAssertEqual(result.failed.first?.error, .insufficientSpace)
        XCTAssertTrue(result.errorMessage?.contains("iPhone") == true)
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 131_072)
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: context.usb.path).filter { $0 != IPhoneUSBExportService.partialDirectoryName }.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: context.work.path).isEmpty)
    }

    func testZIPUSBPreflightUsesExpandedSizeAndPreservesExistingTarget() async throws {
        let context = try makeContext(capacity: { url in url.lastPathComponent == "usb" ? 100 : 1_000_000 })
        let file = try zipFile(context: context, expandedBytes: 131_072)
        let target = context.usb.appendingPathComponent("data.bin")
        let old = Data("existing map".utf8)
        try old.write(to: target)
        let result = await context.service.export([file], to: context.destination, overwriteExisting: true)
        XCTAssertEqual(result.failed.first?.error, .insufficientSpace)
        XCTAssertTrue(result.errorMessage?.contains("USB") == true)
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 131_072)
        XCTAssertEqual(try Data(contentsOf: target), old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testRetainedZIPExtractionDoesNotRequireExpandedIPhoneCapacityAgain() async throws {
        let probe = CapacityTestProbe()
        let fileManager = CapacityCancelFirstZIPPartialFileManager()
        let context = try makeContext(capacity: { url in
            if url.lastPathComponent == "usb" { return 1_000_000 }
            return probe.nextIPhoneCapacity()
        }, fileManager: fileManager)
        let file = try zipFile(context: context, expandedBytes: 131_072)
        let first = await Task { await context.service.export([file], to: context.destination, preservePartialOnCancellation: true) }.value
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(probe.iPhoneQueries, 1)
        let second = await context.service.export([file], to: context.destination, preservePartialOnCancellation: true)
        XCTAssertTrue(second.failed.isEmpty, second.errorMessage ?? "")
        XCTAssertEqual(probe.iPhoneQueries, 1, "Validated extraction reuse must not preflight the full iPhone allocation twice")
        XCTAssertEqual(try Data(contentsOf: context.usb.appendingPathComponent("data.bin")), Data(repeating: 0x4d, count: 131_072))
    }

    func testValidatedZIPPartialFitsOnlyRemainingExpandedBytes() async throws {
        let probe = CapacityTestProbe()
        let context = try makeContext(capacity: { url in
            url.lastPathComponent == "usb" ? probe.usbAvailable : probe.nextIPhoneCapacity()
        }, fileManager: CapacityCancelFirstZIPPartialFileManager())
        let file = try zipFile(context: context, expandedBytes: 131_072)
        let first = await Task { await context.service.export([file], to: context.destination, preservePartialOnCancellation: true) }.value
        XCTAssertTrue(first.cancelled)
        let partial = try zipPartialURL(context: context)
        try Data(repeating: 0x4d, count: 131_068).write(to: partial)
        probe.setUSBAvailable(4)
        let second = await context.service.export([file], to: context.destination, preservePartialOnCancellation: true)
        XCTAssertTrue(second.failed.isEmpty, second.errorMessage ?? "")
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 4)
        XCTAssertEqual(probe.iPhoneQueries, 1)
        XCTAssertEqual(try Data(contentsOf: context.usb.appendingPathComponent("data.bin")), Data(repeating: 0x4d, count: 131_072))
    }

    func testZIPCapacityShortageRetainsValidatedExtractionAndPartial() async throws {
        let probe = CapacityTestProbe()
        let context = try makeContext(capacity: { url in
            url.lastPathComponent == "usb" ? probe.usbAvailable : probe.nextIPhoneCapacity()
        }, fileManager: CapacityCancelFirstZIPPartialFileManager())
        let file = try zipFile(context: context, expandedBytes: 131_072)
        let first = await Task { await context.service.export([file], to: context.destination, preservePartialOnCancellation: true) }.value
        XCTAssertTrue(first.cancelled)
        let partial = try zipPartialURL(context: context)
        let existing = Data(repeating: 0x4d, count: 131_068)
        try existing.write(to: partial)
        probe.setUSBAvailable(1)
        let second = await context.service.export([file], to: context.destination, preservePartialOnCancellation: true)
        XCTAssertEqual(second.failed.first?.error, .insufficientSpace)
        XCTAssertEqual(try Data(contentsOf: partial), existing)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: context.work.path).isEmpty)
        probe.setUSBAvailable(4)
        let third = await context.service.export([file], to: context.destination, preservePartialOnCancellation: true)
        XCTAssertTrue(third.failed.isEmpty, third.errorMessage ?? "")
        XCTAssertEqual(probe.iPhoneQueries, 1)
    }

    func testRejectedZIPPartialNeedsFullRewriteAndPreservesOriginalArchive() async throws {
        let probe = CapacityTestProbe()
        let context = try makeContext(capacity: { url in
            url.lastPathComponent == "usb" ? probe.usbAvailable : probe.nextIPhoneCapacity()
        }, fileManager: CapacityCancelFirstZIPPartialFileManager())
        let file = try zipFile(context: context, expandedBytes: 131_072)
        let original = try Data(contentsOf: file.url)
        let first = await Task { await context.service.export([file], to: context.destination, preservePartialOnCancellation: true) }.value
        XCTAssertTrue(first.cancelled)
        let partial = try zipPartialURL(context: context)
        try Data(repeating: 0x58, count: 131_068).write(to: partial)
        probe.setUSBAvailable(4)
        let second = await context.service.export([file], to: context.destination, preservePartialOnCancellation: true)
        XCTAssertEqual(second.failed.first?.error, .insufficientSpace)
        XCTAssertEqual(context.progress.snapshot().capacityCheck?.requiredBytes, 131_072)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usb.appendingPathComponent("data.bin").path))
        XCTAssertEqual(try Data(contentsOf: file.url), original)
    }

    private func zipPartialURL(context: CapacityExportContext) throws -> URL {
        let root = context.usb.appendingPathComponent(IPhoneUSBExportService.partialDirectoryName)
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".partial") })
        return root.appendingPathComponent(name).appendingPathComponent("data.bin")
    }

    private func makeContext(capacity: @escaping StorageCapacityPreflight.Query, fileManager: FileManager = .default) throws -> CapacityExportContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("received")
        let usb = root.appendingPathComponent("usb")
        let work = root.appendingPathComponent("zip-work")
        for url in [source, usb, work] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let decisions = try IPhoneUSBDeletionDecisionStore(fileURL: root.appendingPathComponent("decisions.json"))
        let progress = USBReceiveProgressStore()
        let service = IPhoneUSBExportService(deletionStore: decisions, fileManager: fileManager,
            startAccessing: { _ in true }, stopAccessing: { _ in }, volumeIdentity: { _ in "capacity-test-volume" },
            progressStore: progress, zipWorkingDirectory: work, capacityQuery: capacity)
        return CapacityExportContext(source: source, usb: usb, work: work, decisions: decisions, progress: progress,
            service: service, destination: USBBookmarkDestination(url: usb, volumeID: "capacity-test-volume", displayName: "Test USB", isStale: false))
    }

    private func storedFile(_ name: String, data: Data, in root: URL) throws -> IPhoneStoredFile {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return IPhoneStoredFile(id: url.path, url: url, name: name, size: Int64(data.count),
            modifiedAt: values.contentModificationDate ?? Date(), receivedRecord: nil)
    }

    private func zipFile(context: CapacityExportContext, expandedBytes: Int) throws -> IPhoneStoredFile {
        let payload = context.work.appendingPathComponent("data.bin")
        try Data(repeating: 0x4d, count: expandedBytes).write(to: payload)
        let zip = context.source.appendingPathComponent("large.zip")
        try FileManager.default.zipItem(at: payload, to: zip, compressionMethod: .deflate)
        try FileManager.default.removeItem(at: payload)
        let values = try zip.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return IPhoneStoredFile(id: zip.path, url: zip, name: "large.zip", size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? Date(), receivedRecord: nil)
    }

    private func partialURL(for file: IPhoneStoredFile, context: CapacityExportContext) throws -> URL {
        let identifier = IPhoneUSBExportService.resumeIdentifier(for: file, destination: context.destination,
            archiveMode: .keepArchive, sourceSize: file.size,
            sourceModifiedAt: try file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let root = context.usb.appendingPathComponent(IPhoneUSBExportService.partialDirectoryName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("export-\(identifier.uuidString.lowercased()).partial")
    }
}

private struct CapacityExportContext {
    let source: URL
    let usb: URL
    let work: URL
    let decisions: IPhoneUSBDeletionDecisionStore
    let progress: USBReceiveProgressStore
    let service: IPhoneUSBExportService
    let destination: USBBookmarkDestination
}

private final class CapacityTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var usb = Int64(1_000_000)
    var iPhoneQueries: Int { lock.withLock { count } }
    var usbAvailable: Int64 { lock.withLock { usb } }
    func setUSBAvailable(_ value: Int64) { lock.withLock { usb = value } }
    func nextIPhoneCapacity() -> Int64 {
        lock.withLock {
            count += 1
            return count == 1 ? 1_000_000 : 0
        }
    }
}

private final class CapacityCancelFirstZIPPartialFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        let shouldCancel = lock.withLock { () -> Bool in
            guard !cancelled, path.contains("export-"), path.contains(".partial/") else { return false }
            cancelled = true
            return true
        }
        if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
        return created
    }
}
