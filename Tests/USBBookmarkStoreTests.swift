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

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
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
