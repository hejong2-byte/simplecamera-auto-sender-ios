import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBBookmarkStoreTests: XCTestCase {
    func testBookmarkRoundTripPreservesVolumeIdentityAndReportsStaleResolution() throws {
        let stateDirectory = temporaryDirectory()
        let folderURL = URL(fileURLWithPath: "/Volumes/WORK USB", isDirectory: true)
        let codec = FakeUSBBookmarkCodec(
            bookmark: Data("bookmark".utf8),
            resolution: USBBookmarkResolution(url: folderURL, isStale: true)
        )
        let store = USBBookmarkStore(
            fileURL: stateDirectory.appendingPathComponent("usb-destination.json"),
            codec: codec
        )

        try store.save(
            folderURL: folderURL,
            volumeID: "volume-123",
            displayName: "WORK USB"
        )
        let reopened = USBBookmarkStore(
            fileURL: stateDirectory.appendingPathComponent("usb-destination.json"),
            codec: codec
        )
        let destination = try XCTUnwrap(reopened.resolve())

        XCTAssertEqual(destination.url, folderURL)
        XCTAssertEqual(destination.volumeID, "volume-123")
        XCTAssertEqual(destination.displayName, "WORK USB")
        XCTAssertTrue(destination.isStale)
    }

    func testSavingSelectedFolderAgainReplacesStaleBookmarkAndMetadata() throws {
        let stateDirectory = temporaryDirectory()
        let codec = ReplacingUSBBookmarkCodec()
        let store = USBBookmarkStore(
            fileURL: stateDirectory.appendingPathComponent("usb-destination.json"),
            codec: codec
        )
        let oldURL = URL(fileURLWithPath: "/Volumes/OLD", isDirectory: true)
        let newURL = URL(fileURLWithPath: "/Volumes/NEW", isDirectory: true)

        try store.save(folderURL: oldURL, volumeID: "old-volume", displayName: "OLD")
        XCTAssertTrue(try XCTUnwrap(store.resolve()).isStale)
        try store.save(folderURL: newURL, volumeID: "new-volume", displayName: "NEW")
        let refreshed = try XCTUnwrap(store.resolve())

        XCTAssertFalse(refreshed.isStale)
        XCTAssertEqual(refreshed.url, newURL)
        XCTAssertEqual(refreshed.volumeID, "new-volume")
        XCTAssertEqual(refreshed.displayName, "NEW")
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class ReplacingUSBBookmarkCodec: USBBookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0

    func makeBookmark(for url: URL) throws -> Data {
        lock.withLock {
            nextID += 1
            return Data("\(nextID)|\(url.path)".utf8)
        }
    }

    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        let parts = String(decoding: data, as: UTF8.self).split(
            separator: "|",
            maxSplits: 1
        )
        return USBBookmarkResolution(
            url: URL(fileURLWithPath: String(parts[1]), isDirectory: true),
            isStale: parts[0] == "1"
        )
    }
}

private struct FakeUSBBookmarkCodec: USBBookmarkCoding {
    let bookmark: Data
    let resolution: USBBookmarkResolution

    func makeBookmark(for url: URL) throws -> Data { bookmark }
    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        XCTAssertEqual(data, bookmark)
        return resolution
    }
}
