import CryptoKit
import Foundation

struct UploadFileFingerprint: Sendable, Equatable {
    let sha256: String
    let size: Int64
    let remoteID: String
}

enum UploadFileFingerprinter {
    static func fingerprint(fileURL: URL) throws -> UploadFileFingerprint {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            size += Int64(chunk.count)
            hasher.update(data: chunk)
        }

        let digest = Array(hasher.finalize())
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        var uuidBytes = Array(digest.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
        return UploadFileFingerprint(
            sha256: hash,
            size: size,
            remoteID: uuid.uuidString.lowercased()
        )
    }
}
