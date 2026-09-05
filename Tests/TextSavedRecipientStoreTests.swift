import XCTest
@testable import SimpleCameraAutoSender

final class TextSavedRecipientStoreTests: XCTestCase {
    func testSaveRenameSelectAndReloadPreservesOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("saved-recipients.json")
        let store = TextSavedRecipientStore(fileURL: fileURL)

        _ = try await store.save(code: "709592", name: " 행정망 PC ")
        _ = try await store.save(code: "123456", name: "아이폰")
        _ = try await store.select(code: "709592")
        _ = try await store.save(code: "709592", name: "행정망 업무 PC")

        let reloaded = try await TextSavedRecipientStore(fileURL: fileURL).load()
        XCTAssertEqual(
            reloaded.recipients.map(\.displayLabel),
            ["행정망 업무 PC · 709592", "아이폰 · 123456"]
        )
        XCTAssertEqual(reloaded.selectedCode, "709592")
    }

    func testSixthDistinctRecipientIsRejectedButExistingCodeCanBeRenamed() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TextSavedRecipientStore(
            fileURL: root.appendingPathComponent("saved-recipients.json")
        )
        for number in 100000..<100005 {
            _ = try await store.save(code: String(number), name: "기기 \(number)")
        }

        await assertStoreError(.limitReached) {
            _ = try await store.save(code: "100005", name: "여섯째")
        }
        let renamed = try await store.save(code: "100000", name: "첫 기기")

        XCTAssertEqual(renamed.recipients.count, 5)
        XCTAssertEqual(renamed.recipients[0].displayLabel, "첫 기기 · 100000")
    }

    func testInvalidCodeAndEmptyNameAreRejected() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TextSavedRecipientStore(
            fileURL: root.appendingPathComponent("saved-recipients.json")
        )

        await assertStoreError(.invalidCode) {
            _ = try await store.save(code: "１２３４５６", name: "전각 숫자")
        }
        await assertStoreError(.invalidCode) {
            _ = try await store.save(code: "12345", name: "다섯 자리")
        }
        await assertStoreError(.emptyName) {
            _ = try await store.save(code: "123456", name: " \n\t ")
        }
    }

    func testLoadKeepsOnlyFirstFiveValidUniqueRecipientsAndValidSelection() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("saved-recipients.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw: [String: Any] = [
            "recipients": [
                ["code": "100000", "name": "첫째"],
                ["code": "100000", "name": "중복"],
                ["code": "wrong", "name": "잘못된 코드"],
                ["code": "100001", "name": "  "],
                ["code": "100002", "name": "둘째"],
                ["code": "100003", "name": "셋째"],
                ["code": "100004", "name": "넷째"],
                ["code": "100005", "name": "다섯째"],
                ["code": "100006", "name": "여섯째"]
            ],
            "selectedCode": "100005"
        ]
        try JSONSerialization.data(withJSONObject: raw).write(to: fileURL)

        let loaded = try await TextSavedRecipientStore(fileURL: fileURL).load()

        XCTAssertEqual(
            loaded.recipients.map(\.code),
            ["100000", "100002", "100003", "100004", "100005"]
        )
        XCTAssertEqual(loaded.selectedCode, "100005")
    }

    func testUndecodableFileLoadsEmptyWithoutRewritingIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("saved-recipients.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("not-json".utf8)
        try original.write(to: fileURL)

        let loaded = try await TextSavedRecipientStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded, .empty)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testDeleteClearsSelectionButDoesNotRemoveOtherRecipients() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TextSavedRecipientStore(
            fileURL: root.appendingPathComponent("saved-recipients.json")
        )
        _ = try await store.save(code: "709592", name: "행정망 PC")
        _ = try await store.save(code: "123456", name: "아이폰")
        _ = try await store.select(code: "709592")

        let state = try await store.delete(code: "709592")

        XCTAssertEqual(state.recipients.map(\.code), ["123456"])
        XCTAssertNil(state.selectedCode)
    }

    func testFailedPersistenceKeepsPreviouslySavedFileAndMemoryState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("saved-recipients.json")
        let initialStore = TextSavedRecipientStore(fileURL: fileURL)
        _ = try await initialStore.save(code: "709592", name: "행정망 PC")

        let failingStore = TextSavedRecipientStore(
            fileURL: fileURL,
            persistence: { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        _ = try await failingStore.load()
        do {
            _ = try await failingStore.save(code: "123456", name: "아이폰")
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }

        let memoryState = try await failingStore.load()
        let diskState = try await TextSavedRecipientStore(fileURL: fileURL).load()
        XCTAssertEqual(memoryState.recipients.map(\.code), ["709592"])
        XCTAssertEqual(diskState.recipients.map(\.code), ["709592"])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TextSavedRecipientStoreTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private func assertStoreError(
        _ expected: TextSavedRecipientStoreError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? TextSavedRecipientStoreError, expected)
        }
    }
}
