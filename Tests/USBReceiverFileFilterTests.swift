import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverFileFilterTests: XCTestCase {
    func testPhotoVideoDocumentZIPAndOtherFiltersUseNamesOnly() async throws {
        let names = ["사진.JPG", "사진.heic", "그림.PNG", "영상.MOV", "영상.mp4",
                     "보고.PDF", "보고.hwp", "보고.hwpx", "보고.docx", "표.xlsx",
                     "발표.pptx", "메모.txt", "자료.ZIP", "지도.spd.000", "무확장자"]
        let fixture = try makeFixture(names: names)
        await fixture.model.refresh()
        let all = fixture.model.storedFiles
        let groups: [(IPhoneStoredFileTypeFilter, Set<String>)] = [
            (.photos, ["사진.JPG", "사진.heic", "그림.PNG"]),
            (.videos, ["영상.MOV", "영상.mp4"]),
            (.documents, ["보고.PDF", "보고.hwp", "보고.hwpx", "보고.docx", "표.xlsx", "발표.pptx", "메모.txt"]),
            (.zip, ["자료.ZIP"]),
            (.other, ["지도.spd.000", "무확장자"])
        ]
        for (filter, expectedNames) in groups {
            fixture.model.setStoredFileTypeFilter(filter)
            XCTAssertEqual(fixture.model.visibleStoredFiles, all.filter { expectedNames.contains($0.name) })
        }
        fixture.model.setStoredFileTypeFilter(.all)
        XCTAssertEqual(fixture.model.visibleStoredFiles, all)
        XCTAssertEqual(try fixture.catalog.refresh(), all)
    }

    func testTrimmedCaseInsensitiveSearchCombinesWithTypeAndKeepsCatalogOrder() async throws {
        let fixture = try makeFixture(names: ["회의 Report.PDF", "회의 REPORT.JPG", "회의 메모.hwpx", "다른.pdf"])
        await fixture.model.refresh()
        let original = fixture.model.storedFiles
        fixture.model.setStoredFileSearchText("  report  \n")
        XCTAssertEqual(fixture.model.visibleStoredFiles, original.filter { $0.name.lowercased().contains("report") })
        fixture.model.setStoredFileTypeFilter(.documents)
        XCTAssertEqual(fixture.model.visibleStoredFiles.map(\.name), ["회의 Report.PDF"])
        XCTAssertEqual(fixture.model.storedFileCountText, "1/4개")
        fixture.model.setStoredFileSearchText("  ")
        XCTAssertEqual(Set(fixture.model.visibleStoredFiles.map(\.name)), ["회의 Report.PDF", "회의 메모.hwpx", "다른.pdf"])
        fixture.model.setStoredFileTypeFilter(.all)
        XCTAssertEqual(fixture.model.visibleStoredFiles, original)
    }

    func testKoreanComposedAndDecomposedFilenameSearchMatch() async throws {
        let fixture = try makeFixture(names: ["한글 보고서.pdf", "영문.pdf"])
        await fixture.model.refresh()
        fixture.model.setStoredFileSearchText("한글".decomposedStringWithCanonicalMapping)
        XCTAssertEqual(fixture.model.visibleStoredFiles.map(\.name), ["한글 보고서.pdf"])
        fixture.model.setStoredFileSearchText("보고서".precomposedStringWithCanonicalMapping)
        XCTAssertEqual(fixture.model.visibleStoredFiles.map(\.name), ["한글 보고서.pdf"])
    }

    func testChangingSearchAndTypePrunesInvisibleSelectionsWithoutRestoringThem() async throws {
        let fixture = try makeFixture(names: ["문서.pdf", "사진.jpg", "다른.pdf"])
        await fixture.model.refresh()
        for file in fixture.model.storedFiles { fixture.model.toggleStoredFileSelection(file.id) }
        fixture.model.setStoredFileTypeFilter(.documents)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, Set(fixture.model.visibleStoredFiles.map(\.id)))
        fixture.model.setStoredFileSearchText("문서")
        XCTAssertEqual(fixture.model.selectedStoredFileIDs, Set(fixture.model.visibleStoredFiles.map(\.id)))
        fixture.model.setStoredFileSearchText("")
        fixture.model.setStoredFileTypeFilter(.all)
        XCTAssertEqual(fixture.model.selectedStoredFileIDs.count, 1)
        fixture.model.requestStoredFileDeletion()
        XCTAssertEqual(fixture.model.storedFilesPendingDeletion.map(\.name), ["문서.pdf"])
    }

    func testEmptyCatalogAndEmptyMatchesHaveDifferentMessages() async throws {
        let empty = try makeFixture(names: [])
        await empty.model.refresh()
        XCTAssertEqual(empty.model.storedFileEmptyMessage, "저장된 파일이 없습니다.")
        let fixture = try makeFixture(names: ["파일.pdf"])
        await fixture.model.refresh()
        fixture.model.setStoredFileSearchText("없는 이름")
        XCTAssertTrue(fixture.model.visibleStoredFiles.isEmpty)
        XCTAssertEqual(fixture.model.storedFileEmptyMessage, "검색 조건에 맞는 파일이 없습니다.")
        XCTAssertEqual(fixture.model.storedFileCountText, "0/1개")
    }

    func testPendingDeletionKeepsCapturedFilesAndDisablesFilterChanges() async throws {
        let fixture = try makeFixture(names: ["삭제 확인.pdf", "사진.jpg"])
        await fixture.model.refresh()
        let selected = try XCTUnwrap(fixture.model.storedFiles.first { $0.name == "삭제 확인.pdf" })
        fixture.model.toggleStoredFileSelection(selected.id)
        fixture.model.requestStoredFileDeletion()
        XCTAssertFalse(fixture.model.canEditStoredFileFilters)
        fixture.model.setStoredFileSearchText("사진")
        fixture.model.setStoredFileTypeFilter(.photos)
        XCTAssertEqual(fixture.model.storedFilesPendingDeletion, [selected])
        XCTAssertEqual(fixture.model.storedFileSearchText, "")
        XCTAssertEqual(fixture.model.storedFileTypeFilter, .all)
    }

    func testResetFiltersThenShareKeepsOriginalURLAndBytes() async throws {
        let fixture = try makeFixture(names: ["사진.jpg", "문서.pdf", "자료.zip"])
        await fixture.model.refresh()
        let originals = fixture.model.storedFiles
        let bytes = try originals.map { try Data(contentsOf: $0.url) }
        fixture.model.setStoredFileSearchText("문서")
        fixture.model.setStoredFileTypeFilter(.documents)
        fixture.model.setStoredFileSearchText("")
        fixture.model.setStoredFileTypeFilter(.all)
        for (index, file) in originals.enumerated() {
            fixture.model.shareStoredFile(file)
            XCTAssertEqual(fixture.model.sharingFile?.url, file.url)
            fixture.model.finishSharingStoredFile(error: nil)
            XCTAssertEqual(try Data(contentsOf: file.url), bytes[index])
        }
        XCTAssertEqual(fixture.model.visibleStoredFiles, originals)
    }

    private func makeFixture(names: [String]) throws -> (model: USBReceiverViewModel, catalog: IPhoneReceivedFileCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try IPhoneReceivedFileCatalog(receivedDirectory: root.appendingPathComponent("Received"),
            stagingDirectory: root.appendingPathComponent("Staging"), recordsFileURL: root.appendingPathComponent("records.json"))
        for name in names { try Data("original contents".utf8).write(to: catalog.receivedDirectory.appendingPathComponent(name)) }
        let suite = "FileFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = USBReceiverViewModel(uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore()),
            bookmarkStore: USBBookmarkStore(fileURL: root.appendingPathComponent("bookmark.json")),
            registrar: FileFilterRegistrar(), receiveOnce: { .init(discovered: 0, completed: 0) },
            storedFiles: { try catalog.refresh() }, previewStoredFile: { try catalog.previewURL(for: $0) },
            canPreviewFile: { _ in true }, progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "Test iPhone", preferences: USBReceiverPreferences(defaults: defaults))
        return (model, catalog)
    }
}

private struct FileFilterRegistrar: IPhoneReceiverRegistering {
    func register(uploadCredential: String, deviceName: String) async throws -> IPhoneReceiverRegistration {
        throw URLError(.unsupportedURL)
    }
}
