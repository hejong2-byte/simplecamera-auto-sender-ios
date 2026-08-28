import Foundation

final class IPhoneReceiveApprovalStore: @unchecked Sendable {
    private struct Approval: Codable {
        let receiverID: UUID
        let deliveryID: UUID
        let destination: IPhoneReceiveDestination
    }

    private struct State: Codable {
        var version = 1
        var approvals: [Approval] = []
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var state: State?

    init(fileURL: URL) { self.fileURL = fileURL }

    func destinations(receiverID: UUID) throws -> [UUID: IPhoneReceiveDestination] {
        try lock.withLock {
            Dictionary(try load().approvals.filter { $0.receiverID == receiverID }
                .map { ($0.deliveryID, $0.destination) }, uniquingKeysWith: { _, last in last })
        }
    }

    func allowedDeliveryIDs(
        receiverID: UUID,
        destination: IPhoneReceiveDestination,
        resuming legacyIDs: Set<UUID> = []
    ) throws -> Set<UUID> {
        let choices = try destinations(receiverID: receiverID)
        return Set(choices.compactMap { $0.value == destination ? $0.key : nil })
            .union(legacyIDs.filter { choices[$0] == nil })
    }

    func approve(
        _ ids: Set<UUID>,
        receiverID: UUID,
        destination: IPhoneReceiveDestination
    ) throws {
        guard !ids.isEmpty else { return }
        try lock.withLock {
            var next = try load()
            next.approvals.removeAll { $0.receiverID == receiverID && ids.contains($0.deliveryID) }
            next.approvals.append(contentsOf: ids.sorted { $0.uuidString < $1.uuidString }.map {
                Approval(receiverID: receiverID, deliveryID: $0, destination: destination)
            })
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            state = next
        }
    }

    private func load() throws -> State {
        if let state { return state }
        let loaded: State
        if FileManager.default.fileExists(atPath: fileURL.path) {
            loaded = try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
            guard loaded.version == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            loaded = State()
        }
        state = loaded
        return loaded
    }
}
