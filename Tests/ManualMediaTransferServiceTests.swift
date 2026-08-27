import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualMediaTransferServiceTests: XCTestCase {
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
