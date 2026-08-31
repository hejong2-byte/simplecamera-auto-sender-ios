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

struct IPhoneStoredFileDeletionFailure: Sendable, Equatable {
    let name: String
    let message: String
}

struct IPhoneStoredFileDeletionSummary: Sendable, Equatable {
    let deletedIDs: [String]
    let failures: [IPhoneStoredFileDeletionFailure]
}

private enum IPhoneStoredFileDeletionError: LocalizedError {
    case invalidLocation
    case notRegularFile
    case changed
    case pendingReceipt

    var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "앱의 받은 파일 폴더 안에 있는 파일만 삭제할 수 있습니다."
        case .notRegularFile:
            return "폴더나 연결 파일은 삭제하지 않습니다."
        case .changed:
            return "선택한 뒤 파일이 변경되었습니다. 목록에서 다시 선택해 주세요."
        case .pendingReceipt:
            return "수신 완료 확인이 끝나지 않은 파일입니다. 수신이 끝난 뒤 삭제해 주세요."
        }
    }
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

    func delete(
        _ files: [IPhoneStoredFile],
        protectedFileNames: Set<String> = []
    ) -> IPhoneStoredFileDeletionSummary {
        lock.withLock {
            var deletedIDs: [String] = []
            var failures: [IPhoneStoredFileDeletionFailure] = []
            for file in files {
                do {
                    guard !protectedFileNames.contains(file.url.lastPathComponent) else {
                        throw IPhoneStoredFileDeletionError.pendingReceipt
                    }
                    try validateDeletion(file, at: file.url)
                    var coordinationError: NSError?
                    var deletionError: Error?
                    var deleted = false
                    NSFileCoordinator().coordinate(
                        writingItemAt: file.url,
                        options: .forDeleting,
                        error: &coordinationError
                    ) { coordinatedURL in
                        do {
                            try validateDeletion(file, at: coordinatedURL)
                            try fileManager.removeItem(at: coordinatedURL)
                            deleted = true
                        } catch {
                            deletionError = error
                        }
                    }
                    if let deletionError { throw deletionError }
                    if let coordinationError { throw coordinationError }
                    guard deleted else { throw CocoaError(.fileWriteUnknown) }
                    deletedIDs.append(file.id)
                } catch {
                    failures.append(IPhoneStoredFileDeletionFailure(
                        name: file.name,
                        message: error.localizedDescription
                    ))
                }
            }
            // Receipt history stays intact so a deliberately deleted file is not received again.
            return IPhoneStoredFileDeletionSummary(deletedIDs: deletedIDs, failures: failures)
        }
    }

    private func validateDeletion(_ file: IPhoneStoredFile, at url: URL) throws {
        let target = url.standardizedFileURL
        let directory = receivedDirectory.standardizedFileURL
        guard url.isFileURL,
              target.path == file.id,
              target.lastPathComponent == file.name,
              target.deletingLastPathComponent().path == directory.path,
              target.deletingLastPathComponent().resolvingSymlinksInPath().path
                == directory.resolvingSymlinksInPath().path else {
            throw IPhoneStoredFileDeletionError.invalidLocation
        }
        let attributes = try fileManager.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw IPhoneStoredFileDeletionError.notRegularFile
        }
        guard (attributes[.size] as? NSNumber)?.int64Value == file.size,
              attributes[.modificationDate] as? Date == file.modifiedAt,
              records.first(where: { $0.storedName == file.name }) == file.receivedRecord else {
            throw IPhoneStoredFileDeletionError.changed
        }
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
