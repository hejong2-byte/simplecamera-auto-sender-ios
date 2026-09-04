import XCTest
@testable import SimpleCameraAutoSender

final class TextTransferClientTests: XCTestCase {
    func testSendUsesWindowsMailboxMultipartContract() async throws {
        let message = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "  프롬프트\n\t한글🙂\n",
            id: UUID(uuidString: "123e4567-e89b-42d3-a456-426614174111")!,
            now: Date(timeIntervalSince1970: 1_778_115_723)
        )
        let body = try message.encoded()
        let objectID = TextDigest.contentID(body).uuidString.lowercased()
        let transport = TextTransportProbe(replies: [
            .json(#"{"id":"\#(objectID)","complete":false,"uploadId":"upload-1"}"#),
            .json(#"{"partNumber":1,"etag":"etag-1"}"#),
            .json(#"{"id":"\#(objectID)"}"#)
        ])
        let client = TextTransferClient(
            baseURL: URL(string: "https://relay.example/api")!,
            transport: transport
        )

        try await client.send(message, uploadCredential: "upload")

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 3)
        let start = requests[0]
        XCTAssertEqual(
            start.url?.path,
            "/api/mailboxes/53435458-0000-4000-8000-000000654321/files/multipart"
        )
        XCTAssertEqual(start.httpMethod, "POST")
        XCTAssertEqual(start.value(forHTTPHeaderField: "Authorization"), "Bearer upload")
        XCTAssertEqual(start.value(forHTTPHeaderField: "X-Media-Type"), TextTransferConstants.mime)
        XCTAssertEqual(start.value(forHTTPHeaderField: "X-Content-SHA256"), TextDigest.hex(body))
        XCTAssertEqual(start.value(forHTTPHeaderField: "X-File-Size"), String(body.count))

        let part = requests[1]
        XCTAssertEqual(
            part.url?.path,
            "/api/mailboxes/53435458-0000-4000-8000-000000654321/files/\(objectID)/parts/1"
        )
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(part.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first?.value, "upload-1")
        XCTAssertEqual(part.httpBody, body)
        XCTAssertEqual(part.value(forHTTPHeaderField: "X-Part-Size"), String(body.count))

        let complete = requests[2]
        XCTAssertEqual(
            complete.url?.path,
            "/api/mailboxes/53435458-0000-4000-8000-000000654321/files/\(objectID)/complete"
        )
        let completeBody = try XCTUnwrap(complete.httpBody)
        let value = try XCTUnwrap(
            JSONSerialization.jsonObject(with: completeBody) as? [String: Any]
        )
        let parts = try XCTUnwrap(value["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["partNumber"] as? Int, 1)
        XCTAssertEqual(parts.first?["etag"] as? String, "etag-1")
    }

    func testSendRejectsMismatchedStartIDBeforeUploadingBody() async throws {
        let message = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "본문"
        )
        let transport = TextTransportProbe(replies: [
            .json(#"{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","complete":false,"uploadId":"upload-1"}"#)
        ])
        let client = TextTransferClient(
            baseURL: URL(string: "https://relay.example/api")!,
            transport: transport
        )

        await XCTAssertThrowsErrorAsync {
            try await client.send(message, uploadCredential: "upload")
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testListDownloadAndAcknowledgeUseReceiverSecretRoutes() async throws {
        let body = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "도착 본문"
        ).encoded()
        let hash = TextDigest.hex(body)
        let itemID = TextDigest.contentID(body)
        let listBody = try JSONSerialization.data(withJSONObject: [[
            "id": itemID.uuidString.lowercased(),
            "name": "메모.json",
            "contentType": TextTransferConstants.mime,
            "size": body.count,
            "sha256": hash,
            "createdAt": "2026-09-04T01:02:03.000Z"
        ]])
        let transport = TextTransportProbe(replies: [
            .init(data: listBody, status: 200),
            .init(data: body, status: 200, headers: [
                "Content-Type": TextTransferConstants.mime,
                "X-Content-SHA256": hash
            ]),
            .init(data: Data(), status: 204)
        ])
        let client = TextTransferClient(
            baseURL: URL(string: "https://relay.example/api")!,
            transport: transport
        )
        let receiverID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let items = try await client.list(receiverID: receiverID, receiveSecret: "receive")
        let downloaded = try await client.download(
            receiverID: receiverID,
            itemID: itemID,
            receiveSecret: "receive"
        )
        try await client.acknowledge(
            receiverID: receiverID,
            itemID: itemID,
            receiveSecret: "receive"
        )

        XCTAssertEqual(items.map(\.id), [itemID])
        XCTAssertEqual(downloaded, body)
        let requests = await transport.requests()
        XCTAssertEqual(requests[0].url?.path, "/api/iphone-receivers/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/texts")
        XCTAssertEqual(requests[1].url?.path, "/api/iphone-receivers/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/texts/\(itemID.uuidString.lowercased())")
        XCTAssertEqual(requests[2].url?.path, "/api/iphone-receivers/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/texts/\(itemID.uuidString.lowercased())/ack")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer receive")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer receive")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer receive")
    }

    func testListRejectsRowsWhoseContentIDDoesNotMatchHash() async throws {
        let body = Data("본문".utf8)
        let hash = TextDigest.hex(body)
        let listBody = try JSONSerialization.data(withJSONObject: [[
            "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "name": "메모.json",
            "contentType": TextTransferConstants.mime,
            "size": body.count,
            "sha256": hash,
            "createdAt": "2026-09-04T01:02:03.000Z"
        ]])
        let transport = TextTransportProbe(replies: [.init(data: listBody, status: 200)])
        let client = TextTransferClient(
            baseURL: URL(string: "https://relay.example/api")!,
            transport: transport
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.list(
                receiverID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
                receiveSecret: "receive"
            )
        }
    }
}

private struct TextTransportReply: Sendable {
    let data: Data
    let status: Int
    let headers: [String: String]

    init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }

    static func json(_ value: String, status: Int = 200) -> Self {
        Self(data: Data(value.utf8), status: status, headers: ["Content-Type": "application/json"])
    }
}

private actor TextTransportProbe: IPhoneReceiverTransport {
    private var replies: [TextTransportReply]
    private var recorded: [URLRequest] = []

    init(replies: [TextTransportReply]) {
        self.replies = replies
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorded.append(request)
        guard !replies.isEmpty else { throw TextProbeError.noReply }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        return (reply.data, response)
    }

    func requests() -> [URLRequest] { recorded }
    func requestCount() -> Int { recorded.count }
}

enum TextProbeError: Error {
    case noReply
}

func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
