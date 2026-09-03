import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class KakaoFolderStoreTests: XCTestCase {
    func testSelectedFolderIsRestoredByNewStoreWithoutChangingUSBBookmark() throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("카카오톡 다운로드", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let usb = root.appendingPathComponent("usb.json")
        let original = Data("independent USB destination".utf8)
        try original.write(to: usb)
        let state = root.appendingPathComponent("kakao/folder.json")
        let store = KakaoFolderStore(fileURL: state)
        XCTAssertNil(try store.resolve())
        try store.save(folder)

        let restored = try XCTUnwrap(KakaoFolderStore(fileURL: state).resolve())
        XCTAssertEqual(restored.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: usb), original)
    }

    func testMissingFolderAndStaleBookmarkAreRejectedRatherThanAnEmptyFolder() throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("folder.json")
        let store = KakaoFolderStore(fileURL: state)
        try store.save(folder)
        let stale = KakaoFolderStore(fileURL: state, codec: StaleFolderCodec(url: folder))
        XCTAssertThrowsError(try stale.resolve())
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try store.resolve())
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path), "An access failure must not silently erase the saved choice")
    }

    func testRegularFileCannotBeSavedAsFolderAndExistingChoiceRemains() throws {
        let root = try makeRoot()
        let state = root.appendingPathComponent("folder.json")
        let file = root.appendingPathComponent("not-a-folder.txt")
        try Data("original".utf8).write(to: file)
        let store = KakaoFolderStore(fileURL: state)
        try store.save(root)
        let before = try Data(contentsOf: state)
        XCTAssertThrowsError(try store.save(file))
        XCTAssertEqual(try Data(contentsOf: state), before)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private struct StaleFolderCodec: USBBookmarkCoding {
    let url: URL
    func makeBookmark(for url: URL) throws -> Data { Data() }
    func resolve(_ data: Data) throws -> USBBookmarkResolution { .init(url: url, isStale: true) }
}
