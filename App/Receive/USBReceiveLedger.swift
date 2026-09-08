import Foundation

enum USBReceiveState: String, Codable, Sendable {
    case downloading
    case verifying
    case finalizing
    case ackPending
    case completed
    case failed
}

struct USBReceiveCheckpoint: Codable, Equatable, Sendable {
    let deliveryID: UUID
    let fileName: String
    let sha256: String
    let totalBytes: Int64
    var confirmedOffset: Int64
    let destinationVolumeID: String
    var finalFileName: String
    var state: USBReceiveState
    var archiveMode: IPhoneReceiveArchiveMode

    init(
        deliveryID: UUID,
        fileName: String,
        sha256: String,
        totalBytes: Int64,
        confirmedOffset: Int64,
        destinationVolumeID: String,
        finalFileName: String,
        state: USBReceiveState,
        archiveMode: IPhoneReceiveArchiveMode = .keepArchive
    ) {
        self.deliveryID = deliveryID
        self.fileName = fileName
        self.sha256 = sha256
        self.totalBytes = totalBytes
        self.confirmedOffset = confirmedOffset
        self.destinationVolumeID = destinationVolumeID
        self.finalFileName = finalFileName
        self.state = state
        self.archiveMode = archiveMode
    }

    private enum CodingKeys: String, CodingKey {
        case deliveryID
        case fileName
        case sha256
        case totalBytes
        case confirmedOffset
        case destinationVolumeID
        case finalFileName
        case state
        case archiveMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deliveryID = try container.decode(UUID.self, forKey: .deliveryID)
        fileName = try container.decode(String.self, forKey: .fileName)
        sha256 = try container.decode(String.self, forKey: .sha256)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        confirmedOffset = try container.decode(Int64.self, forKey: .confirmedOffset)
        destinationVolumeID = try container.decode(String.self, forKey: .destinationVolumeID)
        finalFileName = try container.decode(String.self, forKey: .finalFileName)
        state = try container.decode(USBReceiveState.self, forKey: .state)
        archiveMode = try container.decodeIfPresent(
            IPhoneReceiveArchiveMode.self,
            forKey: .archiveMode
        ) ?? .keepArchive
    }

    static func safeResumeOffset(
        actualLength: Int64,
        confirmedOffset: Int64,
        chunkSize: Int64
    ) -> Int64 {
        guard chunkSize > 0 else { return 0 }
        let safeLength = max(0, min(actualLength, confirmedOffset))
        return safeLength / chunkSize * chunkSize
    }
}

final class USBReceiveLedger: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var checkpoints: [UUID: USBReceiveCheckpoint]

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let stored = try JSONDecoder().decode(
                [USBReceiveCheckpoint].self,
                from: Data(contentsOf: fileURL)
            )
            checkpoints = Dictionary(uniqueKeysWithValues: stored.map { ($0.deliveryID, $0) })
        } else {
            checkpoints = [:]
        }
    }

    func checkpoint(for deliveryID: UUID) -> USBReceiveCheckpoint? {
        lock.lock()
        defer { lock.unlock() }
        return checkpoints[deliveryID]
    }

    func allCheckpoints() -> [USBReceiveCheckpoint] {
        lock.lock()
        defer { lock.unlock() }
        return checkpoints.values.sorted {
            $0.deliveryID.uuidString < $1.deliveryID.uuidString
        }
    }

    func save(_ checkpoint: USBReceiveCheckpoint) throws {
        try lock.withLock {
            var next = checkpoints
            next[checkpoint.deliveryID] = checkpoint
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let payload = try JSONEncoder().encode(
                next.values.sorted { $0.deliveryID.uuidString < $1.deliveryID.uuidString }
            )
            try payload.write(to: fileURL, options: .atomic)
            checkpoints = next
        }
    }

    func remove(deliveryID: UUID) throws {
        try lock.withLock {
            var next = checkpoints
            next.removeValue(forKey: deliveryID)
            let payload = try JSONEncoder().encode(Array(next.values))
            try payload.write(to: fileURL, options: .atomic)
            checkpoints = next
        }
    }
}

enum USBReceiveIntegrityError: Error, Equatable {
    case invalidRangeResponse
}

enum USBReceiveIntegrity {
    static func validateRange(
        statusCode: Int,
        contentRange: String?,
        contentLength: Int64,
        expectedStart: Int64,
        expectedEnd: Int64,
        totalBytes: Int64
    ) throws {
        let expected = "bytes \(expectedStart)-\(expectedEnd)/\(totalBytes)"
        guard statusCode == 206,
              contentRange == expected,
              contentLength == expectedEnd - expectedStart + 1 else {
            throw USBReceiveIntegrityError.invalidRangeResponse
        }
    }
}
