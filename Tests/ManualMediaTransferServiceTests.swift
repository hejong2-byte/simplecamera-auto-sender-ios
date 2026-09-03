import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualMediaTransferServiceTests: XCTestCase {
    func testSelectedDocumentsKeepSameNamesDistinctContentsAndDoNotUsePhotoKit() async throws {
        let root = temporaryDirectory()
        let originals = try ["first", "second"].map { folder -> URL in
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("카카오톡 자료.hwpx")
            try Data("different original \(folder)".utf8).write(to: url)
            return url
        }
        let hashes = try originals.map { try UploadFileFingerprinter.fingerprint(fileURL: $0) }
        let source = FakeManualMediaSource(directory: root)
        let engine = RecordingManualTransferEngine()
        let store = ManualTransferJobStore(fileURL: root.appendingPathComponent("queue.json"))
        let service = ManualMediaTransferService(source: source, jobStore: store, engine: engine,
            exportDirectory: root.appendingPathComponent("exports"))

        let summary = await service.enqueueFiles(originals + [originals[0], root.appendingPathComponent("missing.zip")])
        let jobs = await engine.recordedJobs()
        let photoRequests = await source.recordedIdentifiers()

        XCTAssertEqual(summary.selected, 3)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.failureCategories, [.fileAccess])
        XCTAssertTrue(photoRequests.isEmpty)
        XCTAssertEqual(jobs.map(\.kind), [.file, .file])
        XCTAssertEqual(jobs.map(\.originalFileName), ["카카오톡 자료.hwpx", "카카오톡 자료.hwpx"])
        XCTAssertEqual(Set(jobs.map(\.remoteID)).count, 2)
        XCTAssertTrue(jobs.allSatisfy { $0.assetIdentifier.hasPrefix("document-") })
        XCTAssertEqual(try originals.map { try UploadFileFingerprinter.fingerprint(fileURL: $0) }, hashes)
    }

    func test300MiBDocumentUsesTenPersistentPartsAndRestoresFileKind() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("large.zip")
        try Data("synthetic large file".utf8).write(to: original)
        let handle = try FileHandle(forWritingTo: original)
        try handle.truncate(atOffset: 300 * 1024 * 1024)
        try handle.close()
        let hash = try UploadFileFingerprinter.fingerprint(fileURL: original)
        let stateURL = root.appendingPathComponent("queue.json")
        let store = ManualTransferJobStore(fileURL: stateURL)
        let engine = RecordingManualTransferEngine()
        let service = ManualMediaTransferService(source: FakeManualMediaSource(directory: root),
            jobStore: store, engine: engine, exportDirectory: root.appendingPathComponent("exports"))
        let summary = await service.enqueueFiles([original])
        let jobs = await engine.recordedJobs()
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(job.totalBytes, 300 * 1024 * 1024)
        XCTAssertEqual(job.parts.count, 10)
        XCTAssertEqual(job.parts.dropLast().map(\.size), Array(repeating: Int64(32 * 1024 * 1024), count: 9))
        XCTAssertEqual(job.parts.last?.size, 12 * 1024 * 1024)
        XCTAssertEqual(job.sha256, hash.sha256)
        XCTAssertEqual(try UploadFileFingerprinter.fingerprint(fileURL: original), hash)

        var state = try await store.load()
        state.jobs = jobs
        try await store.replace(state)
        let restored = try await ManualTransferJobStore(fileURL: stateURL).load()
        XCTAssertEqual(restored.jobs.first?.kind, .file)
        XCTAssertEqual(restored.jobs.first?.exportedFileURL, job.exportedFileURL)
        XCTAssertTrue(job.parts.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
    }

    func testEmptyDocumentSelectionDoesNotCreateAnyBatchOrStagingFile() async throws {
        let root = temporaryDirectory()
        let stateURL = root.appendingPathComponent("queue.json")
        let engine = RecordingManualTransferEngine()
        let service = ManualMediaTransferService(source: FakeManualMediaSource(directory: root),
            jobStore: ManualTransferJobStore(fileURL: stateURL), engine: engine,
            exportDirectory: root.appendingPathComponent("exports"))
        let summary = await service.enqueueFiles([])
        let jobs = await engine.recordedJobs()
        XCTAssertEqual(summary, .empty)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testEnqueuesOnlyDistinctSelectedAssetsAndPreservesOriginalMetadata() async throws {
        let directory = temporaryDirectory()
        let store = ManualTransferJobStore(fileURL: directory.appendingPathComponent("queue.json"))
        let source = FakeManualMediaSource(directory: directory)
        let engine = RecordingManualTransferEngine()
        let service = ManualMediaTransferService(
            source: source,
            jobStore: store,
            engine: engine,
            exportDirectory: directory.appendingPathComponent("exports")
        )

        let summary = await service.enqueue(
            selection: ManualMediaSelection(
                assetIdentifiers: ["selected-1", "selected-1", "selected-2"],
                unavailableCount: 0
            ),
            kind: .photo
        )
        let jobs = await engine.recordedJobs()
        let requestedIdentifiers = await source.recordedIdentifiers()

        XCTAssertEqual(summary, ManualMediaTransferSummary(
            selected: 2,
            uploaded: 0,
            failed: 0,
            failureCategories: []
        ))
        XCTAssertEqual(requestedIdentifiers, ["selected-1", "selected-2"])
        XCTAssertEqual(jobs.map(\.assetIdentifier), ["selected-1", "selected-2"])
        XCTAssertEqual(jobs.map(\.originalFileName), ["selected-1.jpg", "selected-2.jpg"])
        XCTAssertEqual(jobs.map(\.contentType), ["image/jpeg", "image/jpeg"])
        XCTAssertEqual(jobs.map(\.capturedAt), [Date(timeIntervalSince1970: 1_234), Date(timeIntervalSince1970: 1_234)])
        XCTAssertTrue(jobs.allSatisfy { $0.sha256.count == 64 })
        XCTAssertTrue(jobs.allSatisfy { UUID(uuidString: $0.remoteID) != nil })
        XCTAssertTrue(jobs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.exportedFileURL.path)
        })
    }

    func testLargeVideoIsSplitIntoExactPersistentPartsBeforeEnqueue() async throws {
        let directory = temporaryDirectory()
        let store = ManualTransferJobStore(fileURL: directory.appendingPathComponent("queue.json"))
        let source = FakeManualMediaSource(
            directory: directory,
            payloads: ["large": Data((0..<10).map(UInt8.init))]
        )
        let engine = RecordingManualTransferEngine()
        let service = ManualMediaTransferService(
            source: source,
            jobStore: store,
            engine: engine,
            exportDirectory: directory.appendingPathComponent("exports"),
            maxBytes: 100,
            singleRequestMaxBytes: 4,
            multipartPartBytes: 4
        )

        _ = await service.enqueue(
            selection: ManualMediaSelection(assetIdentifiers: ["large"], unavailableCount: 0),
            kind: .video
        )
        let recordedJobs = await engine.recordedJobs()
        let job = try XCTUnwrap(recordedJobs.first)

        XCTAssertEqual(job.totalBytes, 10)
        XCTAssertEqual(job.parts.map(\.number), [1, 2, 3])
        XCTAssertEqual(job.parts.map(\.size), [4, 4, 2])
        XCTAssertTrue(job.parts.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
    }

    func testUnavailableAndExportFailuresPublishAndPersistImmediately() async throws {
        let directory = temporaryDirectory()
        let store = ManualTransferJobStore(fileURL: directory.appendingPathComponent("queue.json"))
        let source = FakeManualMediaSource(
            directory: directory,
            failingIdentifiers: ["bad"]
        )
        let engine = RecordingManualTransferEngine()
        let service = ManualMediaTransferService(
            source: source,
            jobStore: store,
            engine: engine,
            exportDirectory: directory.appendingPathComponent("exports")
        )
        var iterator = await service.updates().makeAsyncIterator()

        let operation = Task {
            await service.enqueue(
                selection: ManualMediaSelection(
                    assetIdentifiers: ["bad", "good"],
                    unavailableCount: 1
                ),
                kind: .video
            )
        }
        let initial = await iterator.next()
        let afterExportFailure = await iterator.next()
        let summary = await operation.value
        let state = try await store.load()
        let queuedIdentifiers = await engine.recordedJobs().map(\.assetIdentifier)

        XCTAssertEqual(initial?.failedCount, 1)
        XCTAssertEqual(afterExportFailure?.failedCount, 2)
        XCTAssertEqual(summary.failed, 2)
        XCTAssertEqual(summary.failureCategories, [.unavailable, .unsupported])
        XCTAssertEqual(state.batches.first?.failedCount, 2)
        XCTAssertEqual(queuedIdentifiers, ["good"])
    }

    func testOversizedExportFailsBeforeAnyNetworkJobIsQueued() async throws {
        let directory = temporaryDirectory()
        let store = ManualTransferJobStore(fileURL: directory.appendingPathComponent("queue.json"))
        let source = FakeManualMediaSource(
            directory: directory,
            payloads: ["large": Data(repeating: 1, count: 6)]
        )
        let engine = RecordingManualTransferEngine()
        let service = ManualMediaTransferService(
            source: source,
            jobStore: store,
            engine: engine,
            exportDirectory: directory.appendingPathComponent("exports"),
            maxBytes: 5
        )

        let summary = await service.enqueue(
            selection: ManualMediaSelection(assetIdentifiers: ["large"], unavailableCount: 0),
            kind: .video
        )
        let jobs = await engine.recordedJobs()

        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.failureCategories, [.tooLarge])
        XCTAssertTrue(jobs.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualMediaTransferServiceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor FakeManualMediaSource: ManualMediaSourcing {
    private let directory: URL
    private let failingIdentifiers: Set<String>
    private let payloads: [String: Data]
    private var requestedIdentifiers: [String] = []

    init(
        directory: URL,
        failingIdentifiers: Set<String> = [],
        payloads: [String: Data] = [:]
    ) {
        self.directory = directory
        self.failingIdentifiers = failingIdentifiers
        self.payloads = payloads
    }

    func exportOriginal(
        assetIdentifier: String,
        kind: ManualMediaKind,
        to directory: URL
    ) async throws -> ManualMediaExport {
        requestedIdentifiers.append(assetIdentifier)
        if failingIdentifiers.contains(assetIdentifier) {
            throw ManualMediaSourceError.unsupportedContentType
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = kind == .video ? "mov" : "jpg"
        let fileURL = directory
            .appendingPathComponent(assetIdentifier)
            .appendingPathExtension(suffix)
        try (payloads[assetIdentifier] ?? Data("content-\(assetIdentifier)".utf8))
            .write(to: fileURL)
        return ManualMediaExport(
            assetIdentifier: assetIdentifier,
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            contentType: kind == .video ? "video/quicktime" : "image/jpeg",
            capturedAt: Date(timeIntervalSince1970: 1_234)
        )
    }

    func recordedIdentifiers() -> [String] {
        requestedIdentifiers
    }
}

private actor RecordingManualTransferEngine: ManualTransferQueueing {
    private var jobs: [ManualTransferJob] = []

    func enqueue(_ jobs: [ManualTransferJob]) async throws {
        self.jobs.append(contentsOf: jobs)
    }

    func updates() async -> AsyncStream<ManualTransferProgress> {
        AsyncStream { continuation in continuation.finish() }
    }

    func recordedJobs() -> [ManualTransferJob] {
        jobs
    }
}
