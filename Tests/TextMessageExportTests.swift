import XCTest
@testable import SimpleCameraAutoSender

final class TextMessageExportTests: XCTestCase {
    func testTemporaryFileUsesStableNameAndExactUTF8Body() throws {
        let id = UUID(uuidString: "123e4567-e89b-42d3-a456-426614174333")!
        let envelope = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "첫째 줄\n둘째 줄 😀",
            id: id,
            now: Date(timeIntervalSince1970: 1_778_115_723)
        )
        let message = TextStoredMessage(
            key: TextMessageKey(direction: .received, id: id),
            envelope: envelope,
            bodySHA256: TextDigest.hex(try envelope.encoded()),
            status: .received,
            readAt: nil
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try TextMessageExport.makeTemporaryFile(
            for: message,
            in: directory
        )

        XCTAssertEqual(
            TextMessageExport.baseName(for: message),
            "SimpleCamera-text-123e4567-e89b-42d3-a456-426614174333"
        )
        XCTAssertEqual(
            url.lastPathComponent,
            "SimpleCamera-text-123e4567-e89b-42d3-a456-426614174333.txt"
        )
        XCTAssertEqual(
            try Data(contentsOf: url),
            Data("첫째 줄\n둘째 줄 😀".utf8)
        )
    }
}
