import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualMediaTransferServiceTests: XCTestCase {
    func testTransfersOnlySelectedIdentifiersOnceAndPreservesMetadata() async throws {
        let directory = temporaryDirectory()
        let ledger = try UploadLedger(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        let source = FakeManualMediaSource(directory: directory)
        let uploader = RecordingManualUploader()
        let service = ManualMediaTransferService(
            source: source,
            ledger: ledger,
            uploader: uploader,
            exportDirectory: directory.appendingPathComponent("exports")
        )

        let summary = await service.send(
            selection: ManualMediaSelection(
                assetIdentifiers: ["selected-1", "selected-1", "selected-2"],
                unavailableCount: 0
            ),
            kind: .photo
        )
        let requestedIdentifiers = await source.requestedIdentifiers

        XCTAssertEqual(summary.uploaded, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(requestedIdentifiers, ["selected-1", "selected-2"])
        XCTAssertEqual(uploader.assetIDs, ["selected-1", "selected-2"])
        XCTAssertEqual(uploader.metadata.map(\.contentType), ["image/jpeg", "image/jpeg"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("exports").path
                + "/selected-1.jpg"
        ))
    }

    func testContinuesAfterFailureAndCountsUnavailablePickerResults() async throws {
        let directory = temporaryDirectory()
        let ledger = try UploadLedger(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        let source = FakeManualMediaSource(
            directory: directory,
            failingIdentifiers: ["bad"]
        )
        let uploader = RecordingManualUploader()
        let service = ManualMediaTransferService(
            source: source,
            ledger: ledger,
            uploader: uploader,
            exportDirectory: directory.appendingPathComponent("exports")
        )

        let summary = await service.send(
            selection: ManualMediaSelection(
                assetIdentifiers: ["bad", "good"],
                unavailableCount: 1
            ),
            kind: .video
        )

        XCTAssertEqual(summary.selected, 3)
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.failed, 2)
        XCTAssertEqual(
            summary.failureCategories,
            Set([.unsupported, .unavailable])
        )
        XCTAssertEqual(uploader.assetIDs, ["good"])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor FakeManualMediaSource: ManualMediaSourcing {
    private let directory: URL
    private let failingIdentifiers: Set<String>
    private(set) var requestedIdentifiers: [String] = []

    init(directory: URL, failingIdentifiers: Set<String> = []) {
        self.directory = directory
        self.failingIdentifiers = failingIdentifiers
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
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let suffix = kind == .video ? "mov" : "jpg"
        let fileURL = directory
            .appendingPathComponent(assetIdentifier)
            .appendingPathExtension(suffix)
        try Data(assetIdentifier.utf8).write(to: fileURL)
        return ManualMediaExport(
            assetIdentifier: assetIdentifier,
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            contentType: kind == .video ? "video/quicktime" : "image/jpeg",
            capturedAt: Date(timeIntervalSince1970: 1_234)
        )
    }
}

private final class RecordingManualUploader: UploadCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedAssetIDs: [String] = []
    private var recordedMetadata: [ManualMediaUploadMetadata] = []

    var assetIDs: [String] { lock.withLock { recordedAssetIDs } }
    var metadata: [ManualMediaUploadMetadata] { lock.withLock { recordedMetadata } }

    func upload(assetID: String, fileURL: URL) async throws {
        XCTFail("수동 전송은 메타데이터 업로드를 사용해야 합니다.")
    }

    func upload(
        assetID: String,
        fileURL: URL,
        metadata: ManualMediaUploadMetadata
    ) async throws {
        lock.withLock {
            recordedAssetIDs.append(assetID)
            recordedMetadata.append(metadata)
        }
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}
