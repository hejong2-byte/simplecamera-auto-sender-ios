import Foundation
import XCTest
import ZIPFoundation
@testable import SimpleCameraAutoSender

final class USBZIPReceivePipelineTests: XCTestCase {
    func testVerifiedZIPExtractsFromPrivateStagingAndCommitsContentsToUSBRoot() throws {
        let context = try makeContext()
        let unrelated = context.usb.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        var phases: [USBZIPReceivePhase] = []

        let result = try context.pipeline.commit(
            zip: context.zip,
            delivery: context.delivery,
            destination: context.usb,
            progress: { phases.append($0.phase) }
        )

        XCTAssertEqual(result.finalFolderName, "")
        XCTAssertEqual(result.extractedBytes, 20)
        XCTAssertEqual(
            try Data(contentsOf: context.usb.appendingPathComponent("docs/report.txt")),
            Data("report-data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: context.usb.appendingPathComponent("root.txt")),
            Data("root-data".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usb.appendingPathComponent("업무자료").path))
        XCTAssertTrue(try context.pipeline.verify(zip: context.zip, committedFolder: context.usb))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.zip.path))
        XCTAssertTrue(phases.contains(.extracting))
        XCTAssertTrue(phases.contains(.copying))
        XCTAssertTrue(phases.contains(.verifying))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.work.path), [])
    }

    func testRootCollisionFailsWithoutRenamingOrOverwritingExistingContents() throws {
        let context = try makeContext()
        let marker = context.usb.appendingPathComponent("root.txt")
        try Data("existing".utf8).write(to: marker)

        XCTAssertThrowsError(try context.pipeline.commit(
            zip: context.zip,
            delivery: context.delivery,
            destination: context.usb,
            progress: { _ in }
        ))

        XCTAssertEqual(try Data(contentsOf: marker), Data("existing".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usb.appendingPathComponent("업무자료").path))
    }

    func testArchiveNameAndSDCardRootWrappersAreRemovedForDirectUSBReceive() throws {
        let root = temporaryDirectory()
        let usb = root.appendingPathComponent("usb", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let fixture = root.appendingPathComponent("fixture", isDirectory: true)
        let archiveName = "싼타페_V11_전체본_SD카드용"
        let map = fixture
            .appendingPathComponent(archiveName)
            .appendingPathComponent("SD_CARD_ROOT")
            .appendingPathComponent("MAP")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        try Data("navigation".utf8).write(to: map.appendingPathComponent("data.bin"))
        let zip = root.appendingPathComponent("\(archiveName).zip")
        try FileManager.default.zipItem(at: fixture, to: zip, shouldKeepParent: false)
        let data = try Data(contentsOf: zip)
        let pipeline = USBZIPReceivePipeline(workingDirectory: work)

        let result = try pipeline.commit(
            zip: zip,
            delivery: delivery(name: "\(archiveName).zip", data: data),
            destination: usb,
            progress: { _ in }
        )

        XCTAssertEqual(result.finalFolderName, "")
        XCTAssertEqual(
            try Data(contentsOf: usb.appendingPathComponent("MAP/data.bin")),
            Data("navigation".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: usb.appendingPathComponent(archiveName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: usb.appendingPathComponent("SD_CARD_ROOT").path))
    }

    func testUnsafeZIPAndCommitFailurePreserveSourceAndUnrelatedUSBData() throws {
        let root = temporaryDirectory()
        let usb = root.appendingPathComponent("usb", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let marker = usb.appendingPathComponent("do-not-delete.txt")
        try Data("safe".utf8).write(to: marker)
        let unsafe = root.appendingPathComponent("unsafe.zip")
        try unsafeZIPData().write(to: unsafe)
        let unsafeDelivery = delivery(name: "unsafe.zip", data: try Data(contentsOf: unsafe))
        let normalPipeline = USBZIPReceivePipeline(workingDirectory: work)

        XCTAssertThrowsError(try normalPipeline.commit(
            zip: unsafe,
            delivery: unsafeDelivery,
            destination: usb,
            progress: { _ in }
        )) { error in
            XCTAssertEqual(error as? USBZIPReceivePipelineError, .unsafeArchive)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsafe.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("safe".utf8))

        let source = root.appendingPathComponent("업무자료.zip")
        try validZIPData().write(to: source)
        let failing = USBZIPReceivePipeline(
            fileManager: FailingZIPCommitFileManager(),
            workingDirectory: work
        )
        XCTAssertThrowsError(try failing.commit(
            zip: source,
            delivery: delivery(name: "업무자료.zip", data: try Data(contentsOf: source)),
            destination: usb,
            progress: { _ in }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("safe".utf8))
        let partial = usb.appendingPathComponent(USBReceiveService.partialDirectoryName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partial.path), [])
    }

    private func makeContext() throws -> Context {
        let root = temporaryDirectory()
        let usb = root.appendingPathComponent("usb", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = root.appendingPathComponent("업무자료.zip")
        let data = validZIPData()
        try data.write(to: zip)
        return Context(
            usb: usb,
            work: work,
            zip: zip,
            delivery: delivery(name: "업무자료.zip", data: data),
            pipeline: USBZIPReceivePipeline(workingDirectory: work)
        )
    }

    private func delivery(name: String, data: Data) -> IPhoneDelivery {
        IPhoneDelivery(
            deliveryID: UUID(),
            fileName: name,
            contentType: "application/zip",
            size: Int64(data.count),
            sha256: "unused-by-pipeline",
            state: .available,
            createdAt: Date(),
            expiresAt: Date.distantFuture,
            deliveredAt: nil
        )
    }

    private func validZIPData() -> Data {
        Data(base64Encoded:
            "UEsDBBQAAAAIANJIKF03rc1dEwAAAAsAAAAPAAAAZG9jcy9yZXBvcnQudHh0KkotyC8q0U1JLEkEAAAA//8DAFBLAwQUAAAACADSSChd+/k8aREAAAAJAAAACAAAAHJvb3QudHh0KsrPL9FNSSxJBAAAAP//AwBQSwECFAAUAAAACADSSChdN63NXRMAAAALAAAADwAAAAAAAAAAAAAAAAAAAAAAZG9jcy9yZXBvcnQudHh0UEsBAhQAFAAAAAgA0kgoXfv5PGkRAAAACQAAAAgAAAAAAAAAAAAAAAAAQAAAAHJvb3QudHh0UEsFBgAAAAACAAIAcwAAAHcAAAAAAA=="
        )!
    }

    private func unsafeZIPData() -> Data {
        Data(base64Encoded:
            "UEsDBBQAAAAIANJIKF1Oa16IFQAAAA0AAAAQAAAALi4vLi4vZXNjYXBlLnR4dErJ183LL9FNLU5OLEgFAAAA//8DAFBLAQIUABQAAAAIANJIKF1Oa16IFQAAAA0AAAAQAAAAAAAAAAAAAAAAAAAAAAAuLi8uLi9lc2NhcGUudHh0UEsFBgAAAAABAAEAPgAAAEMAAAAAAA=="
        )!
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private struct Context {
    let usb: URL
    let work: URL
    let zip: URL
    let delivery: IPhoneDelivery
    let pipeline: USBZIPReceivePipeline
}

private final class FailingZIPCommitFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.path.contains(".partial/") {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
