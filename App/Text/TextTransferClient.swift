import Foundation

struct TextRemoteItem: Decodable, Equatable, Sendable {
    let id: UUID
    let name: String
    let contentType: String
    let size: Int
    let sha256: String
    let createdAt: Date
}

enum TextTransferClientError: Error, Equatable {
    case emptyCredential
    case invalidResponse
    case invalidRemoteItem
    case protocolMismatch
    case server(statusCode: Int, code: String?)
}

protocol TextTransferServing: Sendable {
    func send(_ message: TextMessageEnvelope, uploadCredential: String) async throws
    func list(receiverID: UUID, receiveSecret: String) async throws -> [TextRemoteItem]
    func download(receiverID: UUID, itemID: UUID, receiveSecret: String) async throws -> Data
    func acknowledge(receiverID: UUID, itemID: UUID, receiveSecret: String) async throws
}

struct TextTransferClient: TextTransferServing, Sendable {
    private let requests: TextTransferRequestFactory
    private let transport: any IPhoneReceiverTransport

    init(
        baseURL: URL = AppConfiguration.relayAPIBaseURL,
        transport: any IPhoneReceiverTransport = URLSessionIPhoneReceiverTransport()
    ) {
        requests = TextTransferRequestFactory(baseURL: baseURL)
        self.transport = transport
    }

    func send(_ message: TextMessageEnvelope, uploadCredential: String) async throws {
        let body = try message.encoded()
        let hash = TextDigest.hex(body)
        let objectID = TextDigest.contentID(body)
        let mailbox = try TextMailbox.identifier(for: message.recipient)
        let start = try requests.multipartStart(
            mailbox: mailbox,
            objectID: objectID,
            messageID: message.id,
            size: body.count,
            sha256: hash,
            credential: uploadCredential
        )
        let startResponse = try TextTransferJSON.decoder.decode(
            MultipartStartResponse.self,
            from: try await successfulData(for: start)
        )
        guard startResponse.id == objectID else {
            throw TextTransferClientError.protocolMismatch
        }
        if startResponse.complete == true { return }
        guard let uploadID = startResponse.uploadID,
              !uploadID.isEmpty,
              uploadID.count <= 2_048 else {
            throw TextTransferClientError.protocolMismatch
        }

        let part = try requests.multipartPart(
            mailbox: mailbox,
            objectID: objectID,
            uploadID: uploadID,
            body: body,
            credential: uploadCredential
        )
        let partResponse = try TextTransferJSON.decoder.decode(
            MultipartPartResponse.self,
            from: try await successfulData(for: part)
        )
        guard partResponse.partNumber == 1,
              !partResponse.etag.isEmpty,
              partResponse.etag.count <= 2_048 else {
            throw TextTransferClientError.protocolMismatch
        }

        let complete = try requests.multipartComplete(
            mailbox: mailbox,
            objectID: objectID,
            uploadID: uploadID,
            etag: partResponse.etag,
            credential: uploadCredential
        )
        let completion = try TextTransferJSON.decoder.decode(
            MultipartCompleteResponse.self,
            from: try await successfulData(for: complete)
        )
        guard completion.id == objectID else {
            throw TextTransferClientError.protocolMismatch
        }
    }

    func list(receiverID: UUID, receiveSecret: String) async throws -> [TextRemoteItem] {
        let request = try requests.list(receiverID: receiverID, receiveSecret: receiveSecret)
        let data = try await successfulData(for: request)
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw TextTransferClientError.invalidResponse
        }
        let items = try TextTransferJSON.decoder.decode([TextRemoteItem].self, from: data)
        guard try items.allSatisfy(Self.valid) else {
            throw TextTransferClientError.invalidRemoteItem
        }
        return items
    }

    func download(
        receiverID: UUID,
        itemID: UUID,
        receiveSecret: String
    ) async throws -> Data {
        try await successfulData(for: requests.download(
            receiverID: receiverID,
            itemID: itemID,
            receiveSecret: receiveSecret
        ))
    }

    func acknowledge(
        receiverID: UUID,
        itemID: UUID,
        receiveSecret: String
    ) async throws {
        _ = try await successfulData(for: requests.acknowledge(
            receiverID: receiverID,
            itemID: itemID,
            receiveSecret: receiveSecret
        ))
    }

    private static func valid(_ item: TextRemoteItem) throws -> Bool {
        guard item.contentType == TextTransferConstants.mime,
              item.size > 0,
              item.size <= TextTransferConstants.maxEnvelopeBytes,
              !item.name.isEmpty,
              item.name.count <= 240,
              !item.name.unicodeScalars.contains(where: {
                  $0.value < 32 || $0.value == 127
              }) else { return false }
        return try TextDigest.contentID(hex: item.sha256) == item.id
    }

    private func successfulData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TextTransferClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw TextTransferClientError.server(statusCode: response.statusCode, code: code)
        }
        return data
    }
}

struct TextTransferRequestFactory: Sendable {
    let baseURL: URL

    func multipartStart(
        mailbox: UUID,
        objectID: UUID,
        messageID: UUID,
        size: Int,
        sha256: String,
        credential: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint([
            "mailboxes", mailbox.uuidString.lowercased(), "files", "multipart"
        ]))
        request.httpMethod = "POST"
        request.setValue(try bearer(credential), forHTTPHeaderField: "Authorization")
        request.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256")
        request.setValue(String(size), forHTTPHeaderField: "X-File-Size")
        request.setValue(
            "SimpleCamera-text-\(messageID.uuidString.lowercased()).json",
            forHTTPHeaderField: "X-File-Name"
        )
        request.setValue(TextTransferConstants.mime, forHTTPHeaderField: "X-Media-Type")
        return request
    }

    func multipartPart(
        mailbox: UUID,
        objectID: UUID,
        uploadID: String,
        body: Data,
        credential: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint(
            ["mailboxes", mailbox.uuidString.lowercased(), "files",
             objectID.uuidString.lowercased(), "parts", "1"],
            uploadID: uploadID
        ))
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue(try bearer(credential), forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "X-Part-Size")
        return request
    }

    func multipartComplete(
        mailbox: UUID,
        objectID: UUID,
        uploadID: String,
        etag: String,
        credential: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint(
            ["mailboxes", mailbox.uuidString.lowercased(), "files",
             objectID.uuidString.lowercased(), "complete"],
            uploadID: uploadID
        ))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(MultipartCompletionBody(parts: [
            MultipartCompletedPart(partNumber: 1, etag: etag)
        ]))
        request.setValue(try bearer(credential), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func list(receiverID: UUID, receiveSecret: String) throws -> URLRequest {
        try authenticated(
            method: "GET",
            components: ["iphone-receivers", receiverID.uuidString.lowercased(), "texts"],
            receiveSecret: receiveSecret
        )
    }

    func download(receiverID: UUID, itemID: UUID, receiveSecret: String) throws -> URLRequest {
        try authenticated(
            method: "GET",
            components: ["iphone-receivers", receiverID.uuidString.lowercased(), "texts",
                         itemID.uuidString.lowercased()],
            receiveSecret: receiveSecret
        )
    }

    func acknowledge(receiverID: UUID, itemID: UUID, receiveSecret: String) throws -> URLRequest {
        try authenticated(
            method: "POST",
            components: ["iphone-receivers", receiverID.uuidString.lowercased(), "texts",
                         itemID.uuidString.lowercased(), "ack"],
            receiveSecret: receiveSecret
        )
    }

    private func authenticated(
        method: String,
        components: [String],
        receiveSecret: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint(components))
        request.httpMethod = method
        request.setValue(try bearer(receiveSecret), forHTTPHeaderField: "Authorization")
        return request
    }

    private func endpoint(_ components: [String], uploadID: String? = nil) -> URL {
        var url = components.reduce(baseURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        guard let uploadID else { return url }
        var values = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        values.queryItems = [URLQueryItem(name: "uploadId", value: uploadID)]
        url = values.url!
        return url
    }

    private func bearer(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TextTransferClientError.emptyCredential }
        if value.lowercased().hasPrefix("bearer ") {
            let token = String(value.dropFirst(7))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw TextTransferClientError.emptyCredential }
            return "Bearer \(token)"
        }
        return "Bearer \(value)"
    }
}

private enum TextTransferJSON {
    static var decoder: JSONDecoder { IPhoneReceiverJSON.decoder }
}

private struct MultipartStartResponse: Decodable {
    let id: UUID
    let complete: Bool?
    let uploadID: String?

    enum CodingKeys: String, CodingKey {
        case id, complete
        case uploadID = "uploadId"
    }
}

private struct MultipartPartResponse: Decodable {
    let partNumber: Int
    let etag: String
}

private struct MultipartCompleteResponse: Decodable {
    let id: UUID
}

private struct MultipartCompletionBody: Encodable {
    let parts: [MultipartCompletedPart]
}

private struct MultipartCompletedPart: Encodable {
    let partNumber: Int
    let etag: String
}
