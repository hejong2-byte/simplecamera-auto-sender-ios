import Foundation

enum PCFileMailbox {
    static func identifier(for code: String) throws -> UUID {
        let bytes = Array(code.utf8)
        guard bytes.count == 6,
              let first = bytes.first,
              (49...57).contains(first),
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) }) else {
            throw TextMessageError.invalidCode
        }
        guard let identifier = UUID(
            uuidString: "53434d52-0000-4000-8000-000000\(code)"
        ) else {
            throw TextMessageError.invalidCode
        }
        return identifier
    }
}
