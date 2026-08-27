import Foundation

enum IPhoneReceiverJSON {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let standard = ISO8601DateFormatter()
            guard let date = standard.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 timestamp"
                )
            }
            return date
        }
        return decoder
    }
}

struct IPhoneReceiverIdentity: Codable, Equatable, Sendable {
    let receiverID: UUID
    let code: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case receiverID = "receiverId"
        case code
        case deviceName
    }
}

struct IPhoneReceiverRegistration: Codable, Equatable, Sendable {
    let receiverID: UUID
    let code: String
    let receiveSecret: String
    let deviceName: String

    var identity: IPhoneReceiverIdentity {
        IPhoneReceiverIdentity(
            receiverID: receiverID,
            code: code,
            deviceName: deviceName
        )
    }

    enum CodingKeys: String, CodingKey {
        case receiverID = "receiverId"
        case code
        case receiveSecret
        case deviceName
    }
}

struct IPhoneReceiverCredentials: Equatable, Sendable {
    let identity: IPhoneReceiverIdentity
    let secret: String
}

struct IPhoneReceiveFeatures: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let acceptsRegularFiles: Bool
    let acceptsZeroByte: Bool
    let supportsLocalStorage: Bool

    static let current = Self(
        protocolVersion: 2,
        acceptsRegularFiles: true,
        acceptsZeroByte: true,
        supportsLocalStorage: true
    )
}

enum IPhoneStorageLocation: String, Codable, Sendable, Equatable {
    case iphoneLocal
    case usb
}

enum IPhoneReceiveLeaseMode: String, Sendable, Equatable {
    case foreground
    case background
}

enum IPhoneDeliveryState: String, Codable, Sendable {
    case available
    case leased
    case ackDeleting
    case delivered
}

struct IPhoneDelivery: Codable, Equatable, Sendable {
    let deliveryID: UUID
    let fileName: String
    let contentType: String
    let size: Int64
    let sha256: String
    let state: IPhoneDeliveryState
    let createdAt: Date
    let expiresAt: Date
    let deliveredAt: Date?

    enum CodingKeys: String, CodingKey {
        case deliveryID = "deliveryId"
        case fileName = "name"
        case contentType
        case size
        case sha256
        case state
        case createdAt
        case expiresAt
        case deliveredAt
    }
}

struct IPhoneReceiverRegistrationStore: Sendable {
    private let identityStore: CredentialStore
    private let secretStore: CredentialStore

    init(identityStore: CredentialStore, secretStore: CredentialStore) {
        self.identityStore = identityStore
        self.secretStore = secretStore
    }

    func save(_ registration: IPhoneReceiverRegistration) throws {
        let encoded = try JSONEncoder().encode(registration.identity)
        guard let identity = String(data: encoded, encoding: .utf8) else {
            throw CredentialStoreError.invalidStoredValue
        }
        try secretStore.save(registration.receiveSecret)
        do {
            try identityStore.save(identity)
        } catch {
            try? secretStore.clear()
            throw error
        }
    }

    func load() throws -> IPhoneReceiverCredentials? {
        guard let identityValue = try identityStore.load(),
              let secret = try secretStore.load() else { return nil }
        guard let identityData = identityValue.data(using: .utf8) else {
            throw CredentialStoreError.invalidStoredValue
        }
        let identity: IPhoneReceiverIdentity
        do {
            identity = try JSONDecoder().decode(
                IPhoneReceiverIdentity.self,
                from: identityData
            )
        } catch {
            throw CredentialStoreError.invalidStoredValue
        }
        return IPhoneReceiverCredentials(identity: identity, secret: secret)
    }

    func clear() throws {
        try identityStore.clear()
        try secretStore.clear()
    }
}
