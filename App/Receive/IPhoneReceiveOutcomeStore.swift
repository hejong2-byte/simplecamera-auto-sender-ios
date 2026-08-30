import Foundation

enum IPhoneReceiveOutcomeKind: String, Codable, Sendable, Equatable {
    case saved
    case failed
}

struct IPhoneReceiveOutcome: Codable, Sendable, Equatable {
    let receiverID: UUID
    let kind: IPhoneReceiveOutcomeKind
    let destination: IPhoneReceiveDestination
    let fileName: String?
    let totalCount: Int
    let completedCount: Int
    let message: String
    let occurredAt: Date
}

final class IPhoneReceiveOutcomeStore: @unchecked Sendable {
    private struct State: Codable {
        let version: Int
        let outcome: IPhoneReceiveOutcome
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load(receiverID: UUID) -> IPhoneReceiveOutcome? {
        lock.withLock {
            guard let state = try? readState(),
                  state.version == 1,
                  state.outcome.receiverID == receiverID else {
                return nil
            }
            return state.outcome
        }
    }

    func save(_ outcome: IPhoneReceiveOutcome) throws {
        try lock.withLock {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(State(version: 1, outcome: outcome))
            try data.write(to: fileURL, options: .atomic)
        }
    }

    func clear(receiverID: UUID) throws {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path),
                  let state = try? readState(),
                  state.version == 1,
                  state.outcome.receiverID == receiverID else {
                return
            }
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func readState() throws -> State {
        try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
    }
}
