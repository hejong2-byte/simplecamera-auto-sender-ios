import Foundation

actor UploadLedger {
    private struct Snapshot: Codable {
        var baseline: Date?
        var records: [String: AssetRecord]

        static let empty = Snapshot(baseline: nil, records: [:])
    }

    private let fileURL: URL
    private var snapshot: Snapshot

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } else {
            snapshot = .empty
        }
    }

    static func defaultFileURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("SimpleCameraAutoSender", isDirectory: true)
            .appendingPathComponent("upload-ledger.json")
    }

    func baseline() throws -> Date? {
        snapshot.baseline
    }

    func setBaseline(_ date: Date) throws {
        snapshot.baseline = date
        try persist()
    }

    func record(id: String) throws -> AssetRecord? {
        snapshot.records[id]
    }

    func allRecords() -> [AssetRecord] {
        snapshot.records.values.sorted { $0.createdAt < $1.createdAt }
    }

    func recordDiscovery(id: String, createdAt: Date) throws {
        guard snapshot.records[id] == nil else { return }
        snapshot.records[id] = AssetRecord(
            id: id,
            createdAt: createdAt,
            state: .discovered,
            taskIdentifier: nil,
            retryCount: 0,
            lastError: nil
        )
        try persist()
    }

    func markIgnored(id: String) throws {
        try update(id: id) { record in
            guard !record.state.isTerminal else { return }
            record.state = .ignored
            record.taskIdentifier = nil
            record.lastError = nil
        }
    }

    func markQueued(id: String, taskIdentifier: Int?) throws {
        try update(id: id) { record in
            guard !record.state.isTerminal else { return }
            record.state = .queued
            record.taskIdentifier = taskIdentifier
            record.lastError = nil
        }
    }

    func markUploaded(id: String) throws {
        try update(id: id) { record in
            guard record.state != .ignored else { return }
            record.state = .uploaded
            record.taskIdentifier = nil
            record.lastError = nil
        }
    }

    func markFailed(id: String, category: UploadErrorCategory) throws {
        try update(id: id) { record in
            guard !record.state.isTerminal else { return }
            record.state = .failed
            record.taskIdentifier = nil
            record.retryCount += 1
            record.lastError = category
        }
    }

    func retryableRecords() throws -> [AssetRecord] {
        snapshot.records.values
            .filter { $0.state == .discovered || $0.state == .failed }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func reset() throws {
        snapshot = .empty
        try persist()
    }

    private func update(
        id: String,
        mutation: (inout AssetRecord) -> Void
    ) throws {
        guard var record = snapshot.records[id] else { return }
        mutation(&record)
        snapshot.records[id] = record
        try persist()
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension AssetState {
    var isTerminal: Bool {
        self == .uploaded || self == .ignored
    }
}
