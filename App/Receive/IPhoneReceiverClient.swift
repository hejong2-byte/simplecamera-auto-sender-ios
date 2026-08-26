import Foundation

enum IPhoneReceiverRequestError: Error, Equatable {
    case emptyCredential
    case invalidRange
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
