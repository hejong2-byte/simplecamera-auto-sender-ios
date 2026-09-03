import Foundation

enum ManualTransferStage: String, Codable, Sendable, Equatable {
    case idle
    case preparing
    case starting
    case uploading
    case retrying
    case verifying
    case completed
    case failed
}

enum ManualTransferFailure: Codable, Sendable, Equatable {
    case network
    case authentication
    case server(statusCode: Int, code: String?)
    case unsupported
    case tooLarge
    case fileAccess
    case storage
    case other
}

struct ManualTransferProgress: Codable, Sendable, Equatable {
    let batchID: UUID
    let kind: ManualMediaKind
    let selectedCount: Int
    let currentIndex: Int
    let uploadedCount: Int
    let failedCount: Int
    let stage: ManualTransferStage
    let totalBytes: Int64
    let confirmedBytes: Int64
    let taskBytesSent: Int64
    let retryAttempt: Int
    let failure: ManualTransferFailure?

    var displayedBytesSent: Int64 {
        min(max(confirmedBytes + taskBytesSent, 0), max(totalBytes, 0))
    }

    var percent: Int {
        guard totalBytes > 0 else { return 0 }
        let ratio = Double(displayedBytesSent) / Double(totalBytes)
        return min(100, max(0, Int((ratio * 100).rounded(.down))))
    }

    var completedCount: Int {
        uploadedCount + failedCount
    }
}
