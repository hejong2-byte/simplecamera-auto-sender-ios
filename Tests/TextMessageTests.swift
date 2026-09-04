import XCTest
@testable import SimpleCameraAutoSender

final class TextMessageTests: XCTestCase {
    private let fixture = Data(#"{"format":"simplecamera-text-v1","id":"123e4567-e89b-42d3-a456-426614174111","sender":"123456","recipient":"654321","created_at":"2026-09-04T01:02:03+00:00","text":"  프롬프트\n\t한글🙂\n"}"#.utf8)

    func testDecodesWindowsEnvelopeWithoutChangingText() throws {
        let message = try TextMessageEnvelope.decode(fixture, expectedRecipient: "654321")

        XCTAssertEqual(message.format, "simplecamera-text-v1")
        XCTAssertEqual(message.id.uuidString.lowercased(), "123e4567-e89b-42d3-a456-426614174111")
        XCTAssertEqual(message.sender, "123456")
        XCTAssertEqual(message.recipient, "654321")
        XCTAssertEqual(message.text, "  프롬프트\n\t한글🙂\n")
    }

    func testMailboxDigestAndContentIDMatchWindows() throws {
        XCTAssertEqual(TextTransferConstants.mime, "application/vnd.simplecamera.text+json")
        XCTAssertEqual(TextTransferConstants.maxTextBytes, 1_048_576)
        XCTAssertEqual(
            try TextMailbox.identifier(for: "654321").uuidString.lowercased(),
            "53435458-0000-4000-8000-000000654321"
        )
        XCTAssertEqual(
            TextDigest.hex(fixture),
            "0f1512181ec6da46e59def7c7b4f57fe216265d718e44b6f42a4e4fef768381c"
        )
        let contentID = TextDigest.contentID(fixture)
        XCTAssertEqual(contentID.uuidString.lowercased(), "0f151218-1ec6-4a46-a59d-ef7c7b4f57fe")
        XCTAssertEqual(uuidVersion(contentID), 4)
    }

    func testEncodingUsesExactKeysAndTimezoneBearingDate() throws {
        let message = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "  그대로\n",
            id: UUID(uuidString: "123e4567-e89b-42d3-a456-426614174111")!,
            now: Date(timeIntervalSince1970: 1_788_484_523)
        )
        let data = try message.encoded()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["format", "id", "sender", "recipient", "created_at", "text"])
        XCTAssertEqual(object["text"] as? String, "  그대로\n")
        let timestamp = try XCTUnwrap(object["created_at"] as? String)
        XCTAssertTrue(timestamp.hasSuffix("Z") || timestamp.contains("+00:00"))
        XCTAssertNoThrow(try TextMessageEnvelope.decode(data, expectedRecipient: "654321"))
    }

    func testAcceptsExactlyOneMiBAndRejectsLargerBlankOrNULText() throws {
        let maximum = String(repeating: "a", count: TextTransferConstants.maxTextBytes)
        XCTAssertNoThrow(
            try TextMessageEnvelope.make(sender: "123456", recipient: "654321", text: maximum)
        )
        XCTAssertThrowsError(
            try TextMessageEnvelope.make(sender: "123456", recipient: "654321", text: maximum + "a")
        )
        XCTAssertThrowsError(
            try TextMessageEnvelope.make(sender: "123456", recipient: "654321", text: " \n\t ")
        )
        XCTAssertThrowsError(
            try TextMessageEnvelope.make(sender: "123456", recipient: "654321", text: "앞\0뒤")
        )
    }

    func testRejectsInvalidCodesRecipientMismatchAndMalformedEnvelope() throws {
        for code in ["012345", "12345", "1234567", "12345a"] {
            XCTAssertThrowsError(try TextMailbox.identifier(for: code))
        }
        XCTAssertThrowsError(
            try TextMessageEnvelope.make(sender: "012345", recipient: "654321", text: "본문")
        )
        XCTAssertThrowsError(
            try TextMessageEnvelope.decode(fixture, expectedRecipient: "123456")
        )

        var extra = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture) as? [String: Any]
        )
        extra["extra"] = true
        XCTAssertThrowsError(
            try TextMessageEnvelope.decode(
                JSONSerialization.data(withJSONObject: extra),
                expectedRecipient: "654321"
            )
        )

        var timezoneMissing = extra
        timezoneMissing.removeValue(forKey: "extra")
        timezoneMissing["created_at"] = "2026-09-04T01:02:03"
        XCTAssertThrowsError(
            try TextMessageEnvelope.decode(
                JSONSerialization.data(withJSONObject: timezoneMissing),
                expectedRecipient: "654321"
            )
        )
    }

    private func uuidVersion(_ value: UUID) -> Int {
        withUnsafeBytes(of: value.uuid) { raw in
            Int((raw[6] & 0xf0) >> 4)
        }
    }
}
