import Foundation

enum IPhoneLocalReceiveStage: String, Codable, Sendable {
    case scheduled
    case downloading
    case downloaded
    case verifying
    case finalizing
    case ackPending
    case completed
    case failed
}

struct IPhoneLocalReceiveJob: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let delivery: IPhoneDelivery
    var stage: IPhoneLocalReceiveStage
    var stagingFileName: String?
    var finalFileName: String?
    var bytesReceived: Int64
    var retryCount: Int
    var lastError: String?
}

struct IPhoneLocalReceiveJobState: Codable, Equatable, Sendable {
    let version: Int
    var jobs: [IPhoneLocalReceiveJob]
}

final class IPhoneLocalReceiveJobStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var state: IPhoneLocalReceiveJobState

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            state = try JSONDecoder().decode(
                IPhoneLocalReceiveJobState.self,
                from: Data(contentsOf: fileURL)
            )
        } else {
            state = IPhoneLocalReceiveJobState(version: 1, jobs: [])
        }
    }

    func load() throws -> IPhoneLocalReceiveJobState {
        lock.withLock { state }
    }

    func job(for deliveryID: UUID) -> IPhoneLocalReceiveJob? {
        lock.withLock {
            state.jobs.first { $0.delivery.deliveryID == deliveryID }
        }
    }

    func save(_ job: IPhoneLocalReceiveJob) throws {
        try lock.withLock {
            var next = state
            if let index = next.jobs.firstIndex(where: { $0.id == job.id }) {
                next.jobs[index] = job
            } else {
                next.jobs.append(job)
            }
            next.jobs.sort { $0.id.uuidString < $1.id.uuidString }
            try persist(next)
            state = next
        }
    }

    func remove(deliveryID: UUID) throws {
        try lock.withLock {
            var next = state
            next.jobs.removeAll { $0.delivery.deliveryID == deliveryID }
            try persist(next)
            state = next
        }
    }

    private func persist(_ value: IPhoneLocalReceiveJobState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
    }
}
