import Foundation

struct TextSavedRecipient: Codable, Equatable, Identifiable, Sendable {
    let code: String
    var name: String

    var id: String { code }
    var displayLabel: String { "\(name) · \(code)" }
}

struct TextSavedRecipientState: Codable, Equatable, Sendable {
    var recipients: [TextSavedRecipient]
    var selectedCode: String?

    static let empty = TextSavedRecipientState(recipients: [], selectedCode: nil)
}

enum TextSavedRecipientStoreError: Error, Equatable, LocalizedError {
    case invalidCode
    case emptyName
    case limitReached
    case recipientNotFound

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            return "수신 코드는 숫자 6자리여야 합니다."
        case .emptyName:
            return "수신코드 이름을 입력하세요."
        case .limitReached:
            return "수신코드는 최대 5개까지 저장할 수 있습니다."
        case .recipientNotFound:
            return "저장된 수신코드를 찾지 못했습니다."
        }
    }
}

actor TextSavedRecipientStore {
    static let limit = 5
    typealias Persistence = (Data, URL, FileManager) throws -> Void

    private let fileURL: URL
    private let fileManager: FileManager
    private let persistence: Persistence
    private var cachedState: TextSavedRecipientState?

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        persistence: @escaping Persistence = TextSavedRecipientStore.persistAtomically
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.persistence = persistence
    }

    func load() throws -> TextSavedRecipientState {
        if let cachedState { return cachedState }

        let decoded: TextSavedRecipientState
        if fileManager.fileExists(atPath: fileURL.path) {
            decoded = (try? JSONDecoder().decode(
                TextSavedRecipientState.self,
                from: Data(contentsOf: fileURL)
            )) ?? .empty
        } else {
            decoded = .empty
        }
        let state = Self.sanitized(decoded)
        cachedState = state
        return state
    }

    func save(code: String, name: String) throws -> TextSavedRecipientState {
        let code = try Self.validatedCode(code)
        let name = try Self.validatedName(name)
        var state = try load()

        if let index = state.recipients.firstIndex(where: { $0.code == code }) {
            state.recipients[index].name = name
        } else {
            guard state.recipients.count < Self.limit else {
                throw TextSavedRecipientStoreError.limitReached
            }
            state.recipients.append(TextSavedRecipient(code: code, name: name))
        }
        try persist(state)
        return state
    }

    func select(code: String) throws -> TextSavedRecipientState {
        let code = try Self.validatedCode(code)
        var state = try load()
        guard state.recipients.contains(where: { $0.code == code }) else {
            throw TextSavedRecipientStoreError.recipientNotFound
        }
        state.selectedCode = code
        try persist(state)
        return state
    }

    func delete(code: String) throws -> TextSavedRecipientState {
        let code = try Self.validatedCode(code)
        var state = try load()
        guard let index = state.recipients.firstIndex(where: { $0.code == code }) else {
            throw TextSavedRecipientStoreError.recipientNotFound
        }
        state.recipients.remove(at: index)
        if state.selectedCode == code { state.selectedCode = nil }
        try persist(state)
        return state
    }

    private func persist(_ state: TextSavedRecipientState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try persistence(encoder.encode(state), fileURL, fileManager)
        cachedState = state
    }

    private static func sanitized(
        _ decoded: TextSavedRecipientState
    ) -> TextSavedRecipientState {
        var seen = Set<String>()
        let recipients = decoded.recipients.compactMap { item -> TextSavedRecipient? in
            guard seen.count < limit,
                  let code = try? validatedCode(item.code),
                  let name = try? validatedName(item.name),
                  seen.insert(code).inserted else {
                return nil
            }
            return TextSavedRecipient(code: code, name: name)
        }
        let selectedCode = decoded.selectedCode.flatMap { candidate in
            recipients.contains(where: { $0.code == candidate }) ? candidate : nil
        }
        return TextSavedRecipientState(
            recipients: recipients,
            selectedCode: selectedCode
        )
    }

    private static func validatedCode(_ value: String) throws -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6,
              code.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }) else {
            throw TextSavedRecipientStoreError.invalidCode
        }
        return code
    }

    private static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TextSavedRecipientStoreError.emptyName
        }
        return name
    }

    static func persistAtomically(
        _ data: Data,
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let temporary = parent.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
