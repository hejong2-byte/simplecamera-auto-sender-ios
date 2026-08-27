import Foundation

struct IPhoneReceivedFileRecord: Codable, Equatable, Sendable {
    let deliveryID: UUID
    let originalName: String
    let storedName: String
    let size: Int64
    let sha256: String
    let receivedAt: Date
}

struct IPhoneStoredFile: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let size: Int64
    let modifiedAt: Date
    let receivedRecord: IPhoneReceivedFileRecord?
}

final class IPhoneReceivedFileCatalog: @unchecked Sendable {
    private struct RecordState: Codable {
        let version: Int
        var records: [IPhoneReceivedFileRecord]
    }

    let receivedDirectory: URL
    let stagingDirectory: URL

    private let recordsFileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var records: [IPhoneReceivedFileRecord]

    init(
        receivedDirectory: URL,
        stagingDirectory: URL,
        recordsFileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        self.receivedDirectory = receivedDirectory
        self.stagingDirectory = stagingDirectory
        self.recordsFileURL = recordsFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: receivedDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        var staging = stagingDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try staging.setResourceValues(values)
        if fileManager.fileExists(atPath: recordsFileURL.path) {
            records = try JSONDecoder().decode(
                RecordState.self,
                from: Data(contentsOf: recordsFileURL)
            ).records
        } else {
            records = []
        }
    }

    func save(_ record: IPhoneReceivedFileRecord) throws {
        try lock.withLock {
            var next = records.filter {
                $0.deliveryID != record.deliveryID && $0.storedName != record.storedName
            }
            next.append(record)
            next.sort { $0.deliveryID.uuidString < $1.deliveryID.uuidString }
            try fileManager.createDirectory(
                at: recordsFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(
                RecordState(version: 1, records: next)
            ).write(to: recordsFileURL, options: .atomic)
            records = next
        }
    }

    func record(for deliveryID: UUID) -> IPhoneReceivedFileRecord? {
        lock.withLock { records.first { $0.deliveryID == deliveryID } }
    }

    func refresh() throws -> [IPhoneStoredFile] {
        try lock.withLock {
            let recordsByName = Dictionary(
                records.map { ($0.storedName, $0) },
                uniquingKeysWith: { first, second in
                    first.receivedAt > second.receivedAt ? first : second
                }
            )
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isHiddenKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
            return try fileManager.contentsOfDirectory(
                at: receivedDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ).compactMap { url -> IPhoneStoredFile? in
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isHidden != true else {
                    return nil
                }
                return IPhoneStoredFile(
                    id: url.standardizedFileURL.path,
                    url: url,
                    name: url.lastPathComponent,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    receivedRecord: recordsByName[url.lastPathComponent]
                )
            }.sorted {
                if $0.modifiedAt == $1.modifiedAt { return $0.name < $1.name }
                return $0.modifiedAt > $1.modifiedAt
            }
        }
    }
}
