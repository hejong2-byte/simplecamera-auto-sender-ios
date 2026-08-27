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
    let totalBytes: Int64
    var stage: ManualTransferStage
    var uploadID: String?
    var parts: [ManualTransferPart]
    var failure: ManualTransferFailure?
}

struct ManualTransferQueueState: Codable, Sendable, Equatable {
    var batches: [ManualTransferBatch]
    var jobs: [ManualTransferJob]

    static let empty = ManualTransferQueueState(batches: [], jobs: [])
}

enum ManualTransferJobStoreError: Error {
    case batchNotFound
}

actor ManualTransferJobStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        return try decoder.decode(
            ManualTransferQueueState.self,
            from: Data(contentsOf: fileURL)
        )
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
        } catch {
            try? fileManager.removeItem(at: replacement)
            throw error
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
