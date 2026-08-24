import Foundation

enum AutomaticTransferStage: Sendable, Equatable {
    case idle
    case scanning
    case preparing
    case uploading
    case verifying
    case completed
    case failed
}

struct AutomaticTransferProgress: Sendable, Equatable {
    var runID: UUID
    var stage: AutomaticTransferStage
    var currentIndex: Int
    var totalCount: Int
    var uploadedCount: Int
    var failedCount: Int
    var totalBytes: Int64
    var completedBytes: Int64
    var currentBytesSent: Int64
    var currentBytesTotal: Int64
    var failureCategories: Set<UploadErrorCategory>

    var displayedBytesSent: Int64 {
        min(
            max(completedBytes + currentBytesSent, 0),
            max(totalBytes, 0)
        )
    }

    var percent: Int {
        guard totalBytes > 0 else {
            return stage == .completed ? 100 : 0
        }
        return min(
            Int(Double(displayedBytesSent) / Double(totalBytes) * 100),
            100
        )
    }

    static func idle(runID: UUID = UUID()) -> Self {
        Self(
            runID: runID,
            stage: .idle,
            currentIndex: 0,
            totalCount: 0,
            uploadedCount: 0,
            failedCount: 0,
            totalBytes: 0,
            completedBytes: 0,
            currentBytesSent: 0,
            currentBytesTotal: 0,
            failureCategories: []
        )
    }

    static func scanning(runID: UUID) -> Self {
        var progress = idle(runID: runID)
        progress.stage = .scanning
        return progress
    }
}

final class AutomaticTransferProgressStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = AutomaticTransferProgress.idle()
    private var continuations: [
        UUID: AsyncStream<AutomaticTransferProgress>.Continuation
    ] = [:]

    func publish(_ progress: AutomaticTransferProgress) {
        let currentContinuations = lock.withLock { () -> [
            AsyncStream<AutomaticTransferProgress>.Continuation
        ] in
            latest = progress
            return Array(continuations.values)
        }
        currentContinuations.forEach { continuation in
            _ = continuation.yield(progress)
        }
    }

    func updates() -> AsyncStream<AutomaticTransferProgress> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: subscriberID)
            }
            lock.withLock {
                continuations[subscriberID] = continuation
                _ = continuation.yield(latest)
            }
        }
    }

    private func removeContinuation(id: UUID) {
        _ = lock.withLock {
            continuations.removeValue(forKey: id)
        }
    }
}
