import Foundation

struct ManualTransferBatch: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: ManualMediaKind
    let selectedCount: Int
    var preparedCount: Int
    var uploadedCount: Int
    var failedCount: Int
}

struct ManualTransferPart: Codable, Sendable, Equatable {
    let number: Int
    let fileURL: URL
    let size: Int64
    var etag: String?
    var retryAttempt: Int
}

struct ManualTransferJob: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let batchID: UUID
    let assetIdentifier: String
    let kind: ManualMediaKind
    let selectedCount: Int
    let currentIndex: Int
    let exportedFileURL: URL
    let originalFileName: String
    let contentType: String
    let capturedAt: Date?
    let sha256: String
    let remoteID: String
    let recipientMailboxID: UUID?
    let totalBytes: Int64
    var stage: ManualTransferStage
    var uploadID: String?
    var parts: [ManualTransferPart]
    var failure: ManualTransferFailure?
    var recipientCredentialBinding: String? = nil
    var retryHistoryID: UUID? = nil
}

struct ManualTransferHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let fileName: String
    let kind: ManualMediaKind
    let recipientMailboxID: UUID?
    let completedAt: Date
    let failure: ManualTransferFailure?
    let assetIdentifier: String
    let sha256: String?
    let recipientCredentialBinding: String?
    var retriedAt: Date? = nil

    var canRetry: Bool { failure != nil && retriedAt == nil }
}

struct ManualTransferQueueState: Codable, Sendable, Equatable {
    var batches: [ManualTransferBatch]
    var jobs: [ManualTransferJob]
    var history: [ManualTransferHistoryEntry] = []

    init(batches: [ManualTransferBatch], jobs: [ManualTransferJob], history: [ManualTransferHistoryEntry] = []) {
        self.batches = batches
        self.jobs = jobs
        self.history = history
    }

    private enum CodingKeys: String, CodingKey { case batches, jobs, history }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        batches = try values.decode([ManualTransferBatch].self, forKey: .batches)
        jobs = try values.decode([ManualTransferJob].self, forKey: .jobs)
        history = try values.decodeIfPresent([ManualTransferHistoryEntry].self, forKey: .history) ?? []
    }

    static let empty = ManualTransferQueueState(batches: [], jobs: [])
}

enum ManualTransferJobStoreError: Error {
    case batchNotFound
}

actor ManualTransferJobStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedState: ManualTransferQueueState?
    private var retryClaims: Set<UUID> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> ManualTransferQueueState {
        if let cachedState { return cachedState }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedState = .empty
            return .empty
        }
        let state = try decoder.decode(
            ManualTransferQueueState.self,
            from: Data(contentsOf: fileURL)
        )
        cachedState = state
        return state
    }

    func replace(_ state: ManualTransferQueueState) throws {
        let fileManager = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let replacement = parent.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try encoder.encode(state).write(to: replacement, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: replacement)
            } else {
                try fileManager.moveItem(at: replacement, to: fileURL)
            }
            cachedState = state
        } catch {
            try? fileManager.removeItem(at: replacement)
            throw error
        }
    }

    // The mutation and durable replacement never suspend across another actor call.
    @discardableResult
    func transaction(_ mutate: @Sendable (inout ManualTransferQueueState) -> Void) throws -> ManualTransferQueueState {
        var state = try load()
        mutate(&state)
        if state != cachedState { try replace(state) }
        return state
    }

    func enqueue(_ jobs: [ManualTransferJob]) throws {
        try transaction { state in
            for job in jobs {
                if !state.batches.contains(where: { $0.id == job.batchID }) {
                    state.batches.append(.init(id: job.batchID, kind: job.kind,
                        selectedCount: job.selectedCount, preparedCount: 1, uploadedCount: 0, failedCount: 0))
                }
                if !state.jobs.contains(where: { $0.id == job.id }) {
                    state.jobs.append(job)
                    if let historyID = job.retryHistoryID,
                       let index = state.history.firstIndex(where: { $0.id == historyID }) {
                        state.history[index].retriedAt = Date()
                    }
                }
            }
        }
    }

    func recordHistory(_ entry: ManualTransferHistoryEntry) throws {
        try transaction { state in Self.insertHistory(entry, into: &state) }
    }

    func finishJob(id: UUID, failure: ManualTransferFailure?) throws -> ManualTransferQueueState {
        try transaction { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }),
                  state.jobs[index].stage != .completed, state.jobs[index].stage != .failed,
                  let batch = state.batches.firstIndex(where: { $0.id == state.jobs[index].batchID }) else { return }
            state.jobs[index].stage = failure == nil ? .completed : .failed
            state.jobs[index].failure = failure
            if failure == nil { state.batches[batch].uploadedCount += 1 }
            else { state.batches[batch].failedCount += 1 }
            let job = state.jobs[index]
            Self.insertHistory(.init(id: job.id, fileName: job.originalFileName, kind: job.kind,
                recipientMailboxID: job.recipientMailboxID, completedAt: Date(), failure: failure,
                assetIdentifier: job.assetIdentifier, sha256: job.sha256,
                recipientCredentialBinding: job.recipientCredentialBinding), into: &state)
        }
    }

    static func insertHistory(_ entry: ManualTransferHistoryEntry, into state: inout ManualTransferQueueState) {
        guard !state.history.contains(where: { $0.id == entry.id }) else { return }
        state.history.insert(entry, at: 0)
        state.history = Array(state.history.prefix(100))
    }

    func claimRetry(id: UUID) throws -> ManualTransferHistoryEntry {
        guard let entry = try load().history.first(where: { $0.id == id }) else {
            throw ManualTransferRetryError.notFound
        }
        guard entry.failure != nil else { throw ManualTransferRetryError.notFailed }
        guard entry.retriedAt == nil, retryClaims.insert(id).inserted else {
            throw ManualTransferRetryError.alreadyRetrying
        }
        return entry
    }

    func finishRetry(id: UUID, enqueued: Bool) throws {
        defer { retryClaims.remove(id) }
        guard enqueued else { return }
        try transaction { state in
            if let index = state.history.firstIndex(where: { $0.id == id }), state.history[index].retriedAt == nil {
                state.history[index].retriedAt = Date()
            }
        }
    }

    func upsertBatch(_ batch: ManualTransferBatch) throws {
        var state = try load()
        if let index = state.batches.firstIndex(where: { $0.id == batch.id }) {
            state.batches[index] = batch
        } else {
            state.batches.append(batch)
        }
        try replace(state)
    }

    func advanceBatch(
        id: UUID,
        preparedBy preparedDelta: Int,
        failedBy failedDelta: Int
    ) throws -> ManualTransferBatch {
        var state = try load()
        guard let index = state.batches.firstIndex(where: { $0.id == id }) else {
            throw ManualTransferJobStoreError.batchNotFound
        }
        state.batches[index].preparedCount += preparedDelta
        state.batches[index].failedCount += failedDelta
        let batch = state.batches[index]
        try replace(state)
        return batch
    }

    func upsertJob(_ job: ManualTransferJob) throws {
        var state = try load()
        if let index = state.jobs.firstIndex(where: { $0.id == job.id }) {
            state.jobs[index] = job
        } else {
            state.jobs.append(job)
        }
        try replace(state)
    }

    func removeJob(id: UUID) throws {
        var state = try load()
        state.jobs.removeAll { $0.id == id }
        try replace(state)
    }
}
