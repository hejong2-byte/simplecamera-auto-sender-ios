import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class KakaoFilePickerModelTests: XCTestCase {
    func testFirstSelectionWaitsForFolderDismissalBeforeOpeningFiles() throws {
        let (root, store) = try fixture()
        let model = KakaoFilePickerModel(store: store)
        model.beginFileSelection()
        XCTAssertEqual(model.request, .folder(nil))
        XCTAssertTrue(model.accept([root]).isEmpty, "Choosing a folder must not enqueue a file")
        XCTAssertNil(model.request)
        XCTAssertTrue(model.isPresenting)
        model.didDismiss()
        XCTAssertEqual(model.request, .files(root))
        let selected = root.appendingPathComponent("selected.pdf")
        XCTAssertEqual(model.accept([selected]), [selected])
        model.didDismiss()
        XCTAssertFalse(model.isPresenting)
    }

    func testSavedFolderIsUsedOnNextLaunchAndSettingsReselectDoesNotSend() throws {
        let (root, store) = try fixture()
        try store.save(root)
        let model = KakaoFilePickerModel(store: store)
        model.beginFileSelection()
        guard case .files(let url) = model.request else { return XCTFail("Expected file picker") }
        XCTAssertEqual(url.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
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
