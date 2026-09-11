import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class DocumentFilePickerTests: XCTestCase {
    func testFileSelectionIsCapturedBeforePickerDelegateReturns() {
        let url = URL(fileURLWithPath: "/external/선택 문서.hwpx")
        var capturedURLs: [URL] = []
        let picker = DocumentFilePicker(
            request: .files(nil),
            selectionAccess: DocumentSelectionAccess(
                startAccessing: { _ in false },
                stopAccessing: { _ in }
            ),
            onSelection: {
                capturedURLs = $0
                return nil
            },
            onCancel: { XCTFail("Selection must not be treated as cancellation") }
        )
        let coordinator = picker.makeCoordinator()
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: false
        )

        coordinator.documentPicker(controller, didPickDocumentsAt: [url])

        XCTAssertEqual(
            capturedURLs,
            [url],
            "The sheet can dismiss immediately after this delegate returns, so selection state must be captured synchronously"
        )
    }

    func testFolderSelectionIsSavedBeforePickerDelegateReturns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("기본 파일 폴더", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = KakaoFolderStore(fileURL: root.appendingPathComponent("state/folder.json"))
        let model = KakaoFilePickerModel(store: store)
        model.changeFolder()
        let request = try XCTUnwrap(model.request)
        let picker = DocumentFilePicker(
            request: request,
            selectionAccess: DocumentSelectionAccess(
                startAccessing: { _ in false },
                stopAccessing: { _ in }
            ),
            onSelection: {
                _ = model.accept($0)
                return nil
            },
            onCancel: { XCTFail("Selection must not be treated as cancellation") }
        )
        let coordinator = picker.makeCoordinator()
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )

        coordinator.documentPicker(controller, didPickDocumentsAt: [folder])

        XCTAssertEqual(model.folderName, folder.lastPathComponent)
        XCTAssertNotNil(try store.resolve(), "The chosen default folder must survive a new picker launch")
    }

    func testPickedURLsKeepSecurityScopeUntilAsyncHandoffCompletes() async {
        let url = URL(fileURLWithPath: "/external/카카오톡 문서.hwpx")
        let probe = SecurityScopeProbe()
        let gate = DocumentSelectionGate()
        let callbackFinished = expectation(description: "selection handoff completed")
        let picker = DocumentFilePicker(
            request: .files(nil),
            selectionAccess: DocumentSelectionAccess(
                startAccessing: { selected in
                    probe.start(selected)
                    return true
                },
                stopAccessing: probe.stop
            ),
            onSelection: { urls in
                return {
                    XCTAssertEqual(urls, [url])
                    XCTAssertTrue(probe.isActive(url))
                    await gate.wait()
                    XCTAssertTrue(probe.isActive(url))
                    callbackFinished.fulfill()
                }
            },
            onCancel: { XCTFail("Selection must not be treated as cancellation") }
        )
        let coordinator = picker.makeCoordinator()
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: false
        )

        coordinator.documentPicker(controller, didPickDocumentsAt: [url])

        XCTAssertTrue(probe.isActive(url), "Access must start in the delegate callback")
        await gate.open()
        await fulfillment(of: [callbackFinished], timeout: 2)
        await waitUntil { !probe.isActive(url) }
        XCTAssertFalse(probe.isActive(url), "Access must end after staging handoff returns")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Document selection access did not reach the expected state")
    }
}

private actor DocumentSelectionGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class SecurityScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<URL> = []

    func start(_ url: URL) {
        lock.withLock { _ = active.insert(url) }
    }

    func stop(_ url: URL) {
        lock.withLock { active.remove(url) }
    }

    func isActive(_ url: URL) -> Bool {
        lock.withLock { active.contains(url) }
    }
}
