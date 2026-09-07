import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class KakaoFilePickerModelTests: XCTestCase {
    func testFirstKakaoActionImmediatelySelectsFilesWithoutFolderSetup() throws {
        let (root, store) = try fixture()
        let selected = root.appendingPathComponent("카카오톡 문서.hwpx")
        try Data("document".utf8).write(to: selected)
        let model = KakaoFilePickerModel(store: store)

        model.beginFileSelection()

        XCTAssertEqual(model.request?.id, "files")
        XCTAssertNil(model.request?.directoryURL)
        XCTAssertEqual(model.accept([selected]), [selected])
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(try store.resolve(), "File selection must not silently save a folder")
    }

    func testSavedFolderIsUsedOnNextLaunchAndSettingsReselectDoesNotSend() throws {
        let (root, store) = try fixture()
        try store.save(root)
        let model = KakaoFilePickerModel(store: store)
        model.beginFileSelection()
        guard case .files(let url) = model.request else { return XCTFail("Expected file picker") }
        let savedFolder = try XCTUnwrap(url)
        XCTAssertEqual(savedFolder.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        model.cancel()
        model.didDismiss()
        model.changeFolder()
        XCTAssertTrue(model.accept([root]).isEmpty)
        model.didDismiss()
        XCTAssertNil(model.request)
        XCTAssertFalse(model.isPresenting)
    }

    func testCancellationAndUnavailableBookmarkNeverReturnFiles() throws {
        let (root, store) = try fixture()
        let model = KakaoFilePickerModel(store: store)
        model.beginFileSelection()
        model.cancel()
        model.didDismiss()
        XCTAssertNil(try store.resolve())
        XCTAssertTrue(model.accept([root]).isEmpty)
        XCTAssertFalse(model.isPresenting)

        let folder = root.appendingPathComponent("removed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.save(folder)
        try FileManager.default.removeItem(at: folder)
        model.beginFileSelection()
        XCTAssertNil(model.request)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.isPresenting, "Incoming receive UI must wait for the folder error")
        model.reselectAfterError()
        XCTAssertEqual(model.request, .folder(nil))
    }

    private func fixture() throws -> (URL, KakaoFolderStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, KakaoFolderStore(fileURL: root.appendingPathComponent("state/folder.json")))
    }
}
