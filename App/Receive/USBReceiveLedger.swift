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
    static func isZIPSignature(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let prefix = Array(data.prefix(4))
        return prefix == [0x50, 0x4b, 0x03, 0x04]
            || prefix == [0x50, 0x4b, 0x05, 0x06]
            || prefix == [0x50, 0x4b, 0x07, 0x08]
    }

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
