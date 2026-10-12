import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBZIPSelectionCheckpointTests: XCTestCase {
    func testNewExportPersistsSelectionAndNextWholeArchiveExportClearsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json")
        let store = USBReceiveProgressStore(fileURL: url)
        store.beginExport(fileName: "archive.zip", totalCount: 1, sourceFileIDs: ["archive"],
            archiveMode: .extract, zipSelections: ["archive": ["SD_CARD_ROOT/MAP/update.bin"]])
        try assertSelection(USBReceiveProgressStore(fileURL: url).snapshot())
        store.interruptExport()
        try assertSelection(store.snapshot())
        store.beginExport(fileName: "archive.zip", totalCount: 1, sourceFileIDs: ["archive"],
            archiveMode: .extract)
        XCTAssertNil(store.snapshot().zipSelections)
        XCTAssertNil(USBReceiveProgressStore(fileURL: url).snapshot().zipSelections)
    }

    func testLegacyCheckpointWithoutSelectionDecodesAsWholeArchive() throws {
        let checkpoint = """
        {"stage":"paused","destination":"usb","currentIndex":1,"totalCount":1,
         "completedCount":0,"bytesReceived":12,"totalBytes":100,"sourceFileIDs":["archive"],
         "archiveMode":"extract"}
        """
        let progress = try JSONDecoder().decode(USBReceiveProgress.self, from: Data(checkpoint.utf8))
        XCTAssertNil(progress.zipSelections)
    }

    func testZIPSelectionSurvivesRelaunchPauseAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json")
        let checkpoint = """
        {"stage":"copyingToUSB","destination":"usb","currentIndex":1,"totalCount":1,
         "completedCount":0,"bytesReceived":12,"totalBytes":100,"sourceFileIDs":["archive"],
         "archiveMode":"extract","zipSelections":{"archive":["SD_CARD_ROOT/MAP/update.bin"]}}
        """
        try Data(checkpoint.utf8).write(to: url)
        let store = USBReceiveProgressStore(fileURL: url)
        XCTAssertEqual(store.snapshot().stage, .paused)
        try assertSelection(store.snapshot())
        store.publishFailure("test interruption")
        try assertSelection(store.snapshot())
        let reopened = USBReceiveProgressStore(fileURL: url)
        try assertSelection(reopened.snapshot())
    }

    private func assertSelection(_ progress: USBReceiveProgress, file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(progress))
            as? [String: Any], file: file, line: line)
        let selections = try XCTUnwrap(object["zipSelections"] as? [String: [String]],
            "A resumed subset must not silently become an entire ZIP export", file: file, line: line)
        XCTAssertEqual(selections["archive"], ["SD_CARD_ROOT/MAP/update.bin"], file: file, line: line)
    }
}
