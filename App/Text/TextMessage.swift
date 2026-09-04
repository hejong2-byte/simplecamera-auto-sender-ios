import CryptoKit
import Foundation

enum TextTransferConstants {
    static let format = "simplecamera-text-v1"
    static let mime = "application/vnd.simplecamera.text+json"
    static let maxTextBytes = 1_048_576
    static let maxEnvelopeBytes = maxTextBytes * 6 + 2_048
}

enum TextMessageError: Error, Equatable, LocalizedError {
    case invalidCode
    case blankText
    case containsNUL
    case textTooLarge
    case invalidEnvelope
    case invalidDigest

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            return "수신 코드는 1~9로 시작하는 숫자 6자리여야 합니다."
        case .blankText:
            return "보낼 텍스트를 입력하세요."
        case .containsNUL:
            return "전송할 수 없는 NUL 문자가 포함되어 있습니다."
        case .textTooLarge:
            return "텍스트는 UTF-8 기준 1MB까지 보낼 수 있습니다."
        case .invalidEnvelope:
            return "확인할 수 없는 텍스트 형식입니다."
        case .invalidDigest:
            return "텍스트 해시가 올바르지 않습니다."
        }
    }
}

enum TextMailbox {
    static func identifier(for code: String) throws -> UUID {
        try TextValidation.validateCode(code)
        guard let identifier = UUID(
            uuidString: "53435458-0000-4000-8000-000000\(code)"
        ) else {
            throw TextMessageError.invalidCode
        }
        return identifier
    }
}

enum TextDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func contentID(_ data: Data) -> UUID {
        contentID(bytes: Array(SHA256.hash(data: data).prefix(16)))
    }

    static func contentID(hex digest: String) throws -> UUID {
        guard digest.count == 64,
              digest.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw TextMessageError.invalidDigest
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = digest.startIndex
        for _ in 0..<16 {
            let next = digest.index(index, offsetBy: 2)
            guard let byte = UInt8(digest[index..<next], radix: 16) else {
                throw TextMessageError.invalidDigest
            }
            bytes.append(byte)
            index = next
        }
        return contentID(bytes: bytes)
    }

    private static func contentID(bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        var value = bytes
        value[6] = (value[6] & 0x0f) | 0x40
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }
}

struct TextMessageEnvelope: Codable, Equatable, Sendable, Identifiable {
    let format: String
    let id: UUID
    let sender: String
    let recipient: String
    let createdAt: Date
    let text: String

    enum CodingKeys: String, CodingKey {
        case format, id, sender, recipient, text
        case createdAt = "created_at"
    }

    static func make(
        sender: String,
        recipient: String,
        text: String,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> Self {
        try TextValidation.validateCode(sender)
        try TextValidation.validateCode(recipient)
        try TextValidation.validateText(text)
        guard TextValidation.isVersion4(id) else {
            throw TextMessageError.invalidEnvelope
        }
        return Self(
            format: TextTransferConstants.format,
            id: id,
            sender: sender,
            recipient: recipient,
            createdAt: now,
            text: text
        )
    }

    func encoded() throws -> Data {
        guard format == TextTransferConstants.format,
              TextValidation.isVersion4(id) else {
            throw TextMessageError.invalidEnvelope
        }
        try TextValidation.validateCode(sender)
        try TextValidation.validateCode(recipient)
        try TextValidation.validateText(text)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            try container.encode(formatter.string(from: date))
        }
        let data = try encoder.encode(self)
        guard data.count <= TextTransferConstants.maxEnvelopeBytes else {
            throw TextMessageError.invalidEnvelope
        }
        return data
    }

    static func decode(_ data: Data, expectedRecipient: String) throws -> Self {
        do {
            try TextValidation.validateCode(expectedRecipient)
            guard data.count <= TextTransferConstants.maxEnvelopeBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
                  let rawID = object[CodingKeys.id.rawValue] as? String,
                  let parsedID = UUID(uuidString: rawID),
                  parsedID.uuidString.lowercased() == rawID,
                  TextValidation.isVersion4(parsedID),
                  let rawDate = object[CodingKeys.createdAt.rawValue] as? String,
                  TextValidation.parseDate(rawDate) != nil else {
                throw TextMessageError.invalidEnvelope
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let raw = try container.decode(String.self)
                guard let date = TextValidation.parseDate(raw) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Invalid ISO-8601 timestamp"
                    )
                }
                return date
            }
            let message = try decoder.decode(Self.self, from: data)
            guard message.format == TextTransferConstants.format,
                  message.recipient == expectedRecipient else {
                throw TextMessageError.invalidEnvelope
            }
            try TextValidation.validateCode(message.sender)
            try TextValidation.validateCode(message.recipient)
            try TextValidation.validateText(message.text)
            return message
        } catch {
            throw TextMessageError.invalidEnvelope
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        let rawID = try container.decode(String.self, forKey: .id)
        guard let id = UUID(uuidString: rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid UUID"
            )
        }
        self.id = id
        sender = try container.decode(String.self, forKey: .sender)
        recipient = try container.decode(String.self, forKey: .recipient)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decode(String.self, forKey: .text)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(sender, forKey: .sender)
        try container.encode(recipient, forKey: .recipient)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(text, forKey: .text)
    }

    private init(
        format: String,
        id: UUID,
        sender: String,
        recipient: String,
        createdAt: Date,
        text: String
    ) {
        self.format = format
        self.id = id
        self.sender = sender
        self.recipient = recipient
        self.createdAt = createdAt
        self.text = text
    }
}

private extension TextMessageEnvelope.CodingKeys {
    static let allCases: [Self] = [
        .format, .id, .sender, .recipient, .createdAt, .text
    ]
}

private enum TextValidation {
    static func validateCode(_ code: String) throws {
        let bytes = Array(code.utf8)
        guard bytes.count == 6,
              let first = bytes.first,
              (49...57).contains(first),
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) }) else {
            throw TextMessageError.invalidCode
        }
    }

    static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextMessageError.blankText
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TextMessageError.containsNUL
        }
        guard text.utf8.count <= TextTransferConstants.maxTextBytes else {
            throw TextMessageError.textTooLarge
        }
    }

    static func isVersion4(_ id: UUID) -> Bool {
        withUnsafeBytes(of: id.uuid) { raw in
            (raw[6] & 0xf0) == 0x40 && (raw[8] & 0xc0) == 0x80
        }
    }

    static func parseDate(_ value: String) -> Date? {
        guard value.range(
            of: #"(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
            options: .regularExpression
        ) != nil else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
