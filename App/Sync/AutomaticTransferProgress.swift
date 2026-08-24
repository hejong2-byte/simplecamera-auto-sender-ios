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

final class AutomaticTransferProgressReporter: @unchecked Sendable {
    private let store: AutomaticTransferProgressStore
    private let lock = NSLock()
    private var progress: AutomaticTransferProgress
    private var preparedFileCount = 0
    private var preparationBatchBase = 0

    init(
        store: AutomaticTransferProgressStore,
        runID: UUID = UUID()
    ) {
        self.store = store
        self.progress = .idle(runID: runID)
    }

    func beginScanning() {
        update { value in
            preparationBatchBase = preparedFileCount
            value.stage = .scanning
            value.currentIndex = 0
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
        }
    }

    func beginPreparing(currentIndex: Int, knownCount: Int) {
        update { value in
            value.stage = .preparing
            value.currentIndex = preparationBatchBase + max(currentIndex, 0)
            value.totalCount = max(
                value.totalCount,
                preparationBatchBase + max(knownCount, 0)
            )
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
        }
    }

    func registerPreparedFile(bytes: Int64) {
        update { value in
            preparedFileCount += 1
            value.totalCount = max(value.totalCount, preparedFileCount)
            value.totalBytes += max(bytes, 0)
        }
    }

    func beginUpload(currentIndex: Int, fileBytes: Int64) {
        update { value in
            value.stage = .uploading
            value.currentIndex = max(
                value.uploadedCount + value.failedCount + 1,
                max(currentIndex, 1)
            )
            value.totalCount = max(preparedFileCount, value.currentIndex)
            value.currentBytesSent = 0
            value.currentBytesTotal = max(fileBytes, 0)
        }
    }

    func reportUpload(sent: Int64, total: Int64) {
        update { value in
            value.stage = .uploading
            let reportedTotal = max(total, 0)
            if reportedTotal > 0 && reportedTotal != value.currentBytesTotal {
                value.totalBytes = max(
                    value.totalBytes + reportedTotal - value.currentBytesTotal,
                    0
                )
                value.currentBytesTotal = reportedTotal
            }
            value.currentBytesSent = min(
                max(value.currentBytesSent, max(sent, 0)),
                value.currentBytesTotal
            )
        }
    }

    func markVerifying() {
        update { value in
            value.stage = .verifying
        }
    }

    func finishCurrentFileUploaded(bytes: Int64) {
        update { value in
            let completedFileBytes = value.currentBytesTotal > 0
                ? value.currentBytesTotal
                : max(bytes, 0)
            value.completedBytes = min(
                value.completedBytes + completedFileBytes,
                value.totalBytes
            )
            value.uploadedCount += 1
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
        }
    }

    func finishCurrentFileFailed(
        category: UploadErrorCategory,
        bytes: Int64
    ) {
        update { value in
            if value.currentBytesTotal == 0 && bytes > 0 {
                value.totalBytes += bytes
            }
            value.failedCount += 1
            value.failureCategories.insert(category)
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
        }
    }

    func finishRun(
        uploadedCount: Int,
        failedCount: Int,
        failureCategories: Set<UploadErrorCategory>
    ) {
        update { value in
            value.uploadedCount = max(uploadedCount, 0)
            value.failedCount = max(failedCount, 0)
            value.failureCategories = failureCategories
            value.totalCount = max(
                preparedFileCount,
                value.uploadedCount + value.failedCount
            )
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
            if value.failedCount == 0 {
                value.completedBytes = value.totalBytes
                value.stage = .completed
            } else {
                value.stage = .failed
            }
        }
    }

    private func update(
        _ mutate: (inout AutomaticTransferProgress) -> Void
    ) {
        let snapshot = lock.withLock { () -> AutomaticTransferProgress in
            mutate(&progress)
            return progress
        }
        store.publish(snapshot)
    }
}
