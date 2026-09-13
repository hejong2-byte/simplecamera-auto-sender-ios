import Foundation

enum IPhoneReceiveArchiveMode: String, Codable, Sendable, Equatable {
    case keepArchive
    case extract
}

struct IPhoneReceiveDecision: Codable, Sendable, Equatable {
    let destination: IPhoneReceiveDestination
    let archiveMode: IPhoneReceiveArchiveMode
    let overwriteExisting: Bool

    init(
        destination: IPhoneReceiveDestination,
        archiveMode: IPhoneReceiveArchiveMode,
        overwriteExisting: Bool = false
    ) {
        self.destination = destination
        self.archiveMode = archiveMode
        self.overwriteExisting = overwriteExisting
    }

    private enum CodingKeys: String, CodingKey {
        case destination
        case archiveMode
        case overwriteExisting
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destination = try container.decode(IPhoneReceiveDestination.self, forKey: .destination)
        archiveMode = try container.decode(IPhoneReceiveArchiveMode.self, forKey: .archiveMode)
        overwriteExisting = try container.decodeIfPresent(Bool.self, forKey: .overwriteExisting) ?? false
    }
}

final class IPhoneReceiveApprovalStore: @unchecked Sendable {
    private struct Approval: Codable {
        let receiverID: UUID
        let deliveryID: UUID
        let decision: IPhoneReceiveDecision
    }

    private struct State: Codable {
        var version = 2
        var approvals: [Approval] = []
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private struct LegacyApproval: Decodable {
        let receiverID: UUID
        let deliveryID: UUID
        let destination: IPhoneReceiveDestination
    }

    private struct LegacyState: Decodable {
        let version: Int
        let approvals: [LegacyApproval]
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var state: State?

    init(fileURL: URL) { self.fileURL = fileURL }

    func decisions(receiverID: UUID) throws -> [UUID: IPhoneReceiveDecision] {
        try lock.withLock {
            Dictionary(try load().approvals.filter { $0.receiverID == receiverID }
                .map { ($0.deliveryID, $0.decision) }, uniquingKeysWith: { _, last in last })
        }
    }

    func destinations(receiverID: UUID) throws -> [UUID: IPhoneReceiveDestination] {
        try decisions(receiverID: receiverID).mapValues(\.destination)
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
        decision: IPhoneReceiveDecision
    ) throws {
        guard !ids.isEmpty else { return }
        try lock.withLock {
            var next = try load()
            next.approvals.removeAll { $0.receiverID == receiverID && ids.contains($0.deliveryID) }
            next.approvals.append(contentsOf: ids.sorted { $0.uuidString < $1.uuidString }.map {
                Approval(receiverID: receiverID, deliveryID: $0, decision: decision)
            })
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            state = next
        }
    }

    func approveOverwrite(deliveryID: UUID, receiverID: UUID) throws {
        try lock.withLock {
            var next = try load()
            guard let index = next.approvals.lastIndex(where: {
                $0.receiverID == receiverID && $0.deliveryID == deliveryID
            }) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let stored = next.approvals[index]
            next.approvals[index] = Approval(
                receiverID: receiverID,
                deliveryID: deliveryID,
                decision: IPhoneReceiveDecision(
                    destination: stored.decision.destination,
                    archiveMode: stored.decision.archiveMode,
                    overwriteExisting: true
                )
            )
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            state = next
        }
    }

    func approve(
        _ ids: Set<UUID>,
        receiverID: UUID,
        destination: IPhoneReceiveDestination
    ) throws {
        try approve(
            ids,
            receiverID: receiverID,
            decision: IPhoneReceiveDecision(
                destination: destination,
                archiveMode: .keepArchive
            )
        )
    }

    private func load() throws -> State {
        if let state { return state }
        let loaded: State
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let header = try JSONDecoder().decode(VersionHeader.self, from: data)
            switch header.version {
            case 1:
                let legacy = try JSONDecoder().decode(LegacyState.self, from: data)
                guard legacy.version == 1 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                _ = legacy.approvals
                loaded = State()
            case 2:
                loaded = try JSONDecoder().decode(State.self, from: data)
            default:
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            loaded = State()
        }
        state = loaded
        return loaded
    }
}
