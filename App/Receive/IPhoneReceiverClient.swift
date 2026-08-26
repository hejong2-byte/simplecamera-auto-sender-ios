import Foundation

enum IPhoneReceiverRequestError: Error, Equatable {
    case emptyCredential
    case invalidRange
}

enum IPhoneReceiverClientError: Error, Equatable {
    case invalidResponse
    case server(statusCode: Int, code: String?)
}

protocol IPhoneReceiverTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionIPhoneReceiverTransport: IPhoneReceiverTransport, @unchecked Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

struct IPhoneReceiverRangeChunk: Sendable {
    let data: Data
    let statusCode: Int
    let contentRange: String?
    let contentLength: Int64
}

struct IPhoneReceiverClient: Sendable {
    private let requests: IPhoneReceiverRequestFactory
    private let transport: any IPhoneReceiverTransport

    init(
        baseURL: URL = AppConfiguration.relayAPIBaseURL,
        transport: any IPhoneReceiverTransport = URLSessionIPhoneReceiverTransport()
    ) {
        requests = IPhoneReceiverRequestFactory(baseURL: baseURL)
        self.transport = transport
    }

    func register(
        uploadCredential: String,
        deviceName: String
    ) async throws -> IPhoneReceiverRegistration {
        let request = try requests.registration(
            uploadCredential: uploadCredential,
            deviceName: deviceName
        )
        let data = try await successfulData(for: request)
        return try IPhoneReceiverJSON.decoder.decode(
            IPhoneReceiverRegistration.self,
            from: data
        )
    }

    func list(
        receiverID: UUID,
        receiveSecret: String
    ) async throws -> [IPhoneDelivery] {
        let request = try requests.list(
            receiverID: receiverID.uuidString.lowercased(),
            receiveSecret: receiveSecret
        )
        return try IPhoneReceiverJSON.decoder.decode(
            [IPhoneDelivery].self,
            from: try await successfulData(for: request)
        )
    }

    func lease(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String
    ) async throws -> IPhoneDelivery {
        let request = try requests.lease(
            receiverID: receiverID.uuidString.lowercased(),
            deliveryID: deliveryID.uuidString.lowercased(),
            receiveSecret: receiveSecret
        )
        return try IPhoneReceiverJSON.decoder.decode(
            IPhoneDelivery.self,
            from: try await successfulData(for: request)
        )
    }

    func range(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String,
        start: Int64,
        end: Int64
    ) async throws -> IPhoneReceiverRangeChunk {
        let request = try requests.range(
            receiverID: receiverID.uuidString.lowercased(),
            deliveryID: deliveryID.uuidString.lowercased(),
            receiveSecret: receiveSecret,
            start: start,
            end: end
        )
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IPhoneReceiverClientError.invalidResponse
        }
        return IPhoneReceiverRangeChunk(
            data: data,
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: Int64(
                http.value(forHTTPHeaderField: "Content-Length") ?? ""
            ) ?? Int64(data.count)
        )
    }

    func acknowledge(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String,
        sha256: String
    ) async throws {
        let request = try requests.ack(
            receiverID: receiverID.uuidString.lowercased(),
            deliveryID: deliveryID.uuidString.lowercased(),
            receiveSecret: receiveSecret,
            sha256: sha256
        )
        _ = try await successfulData(for: request)
    }

    private func successfulData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IPhoneReceiverClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(
                [String: String].self,
                from: data
            ))?["error"]
            throw IPhoneReceiverClientError.server(
                statusCode: http.statusCode,
                code: code
            )
        }
        return data
    }
}

struct IPhoneReceiverRequestFactory: Sendable {
    let baseURL: URL

    func registration(uploadCredential: String, deviceName: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint(["iphone-receivers", "register"]))
        request.httpMethod = "POST"
        request.setValue(try bearer(uploadCredential), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["deviceName": deviceName])
        return request
    }

    func list(receiverID: String, receiveSecret: String) throws -> URLRequest {
        try authenticated(
            method: "GET",
            components: ["iphone-receivers", receiverID, "deliveries"],
            receiveSecret: receiveSecret
        )
    }

    func range(
        receiverID: String,
        deliveryID: String,
        receiveSecret: String,
        start: Int64,
        end: Int64
    ) throws -> URLRequest {
        guard start >= 0, end >= start else { throw IPhoneReceiverRequestError.invalidRange }
        var request = try authenticated(
            method: "GET",
            components: ["iphone-receivers", receiverID, "deliveries", deliveryID],
            receiveSecret: receiveSecret
        )
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        return request
    }

    func lease(receiverID: String, deliveryID: String, receiveSecret: String) throws -> URLRequest {
        try authenticated(
            method: "POST",
            components: ["iphone-receivers", receiverID, "deliveries", deliveryID, "lease"],
            receiveSecret: receiveSecret
        )
    }

    func ack(
        receiverID: String,
        deliveryID: String,
        receiveSecret: String,
        sha256: String
    ) throws -> URLRequest {
        var request = try authenticated(
            method: "POST",
            components: ["iphone-receivers", receiverID, "deliveries", deliveryID, "ack"],
            receiveSecret: receiveSecret
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["sha256": sha256])
        return request
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

    private func endpoint(_ components: [String]) -> URL {
        components.reduce(baseURL) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }

    private func bearer(_ value: String) throws -> String {
        let credential = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw IPhoneReceiverRequestError.emptyCredential }
        return credential.lowercased().hasPrefix("bearer ") ? credential : "Bearer \(credential)"
    }
}
