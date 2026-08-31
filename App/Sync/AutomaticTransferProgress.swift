import Foundation

enum AutomaticTransferStage: Sendable, Equatable {
    case idle
    case scanning
    case preparing
    case uploading
    case verifying
    case completed
    case failed
    case paused
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
    var candidateIndex: Int = 0
    var candidateCount: Int = 0

    var displayedBytesSent: Int64 {
        min(
            max(completedBytes + currentBytesSent, 0),
            max(totalBytes, 0)
        )
    }

    var percent: Int {
        guard totalBytes > 0 else {
            return stage == .completed && uploadedCount > 0 ? 100 : 0
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
    private var preparedBytesByID: [String: Int64] = [:]
    private var preparedOrder: [String] = []
    private var uploadedIDs = Set<String>()
    private var failuresByID: [String: UploadErrorCategory] = [:]
    private var currentFileID: String?
    private var anonymousFileNumber = 0

    init(
        store: AutomaticTransferProgressStore,
        runID: UUID = UUID()
    ) {
        self.store = store
        self.progress = .idle(runID: runID)
    }

    func beginScanning() {
        update { value in
            currentFileID = nil
            value.stage = .scanning
            value.currentIndex = 0
            value.candidateIndex = 0
            value.candidateCount = 0
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
        }
    }

    func beginPreparing(currentIndex: Int, knownCount: Int) {
        update { value in
            value.stage = .preparing
            value.candidateIndex = max(currentIndex, 0)
            value.candidateCount = max(knownCount, 0)
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
        }
    }

    func registerPreparedFile(bytes: Int64) {
        let id = lock.withLock { () -> String in
            anonymousFileNumber += 1
            return "automatic-anonymous-\(anonymousFileNumber)"
        }
        registerPreparedFile(id: id, bytes: bytes)
    }

    func registerPreparedFile(id: String, bytes: Int64) {
        update { value in
            let fileBytes = max(bytes, 0)
            if preparedBytesByID[id] == nil {
                preparedOrder.append(id)
            }
            let previousBytes = preparedBytesByID.updateValue(
                fileBytes,
                forKey: id
            ) ?? 0
            value.totalBytes = max(
                value.totalBytes + fileBytes - previousBytes,
                0
            )
            value.totalCount = max(
                value.totalCount,
                preparedBytesByID.count
            )
        }
    }

    func discardUnmatchedFile(id: String) {
        update { value in
            guard !uploadedIDs.contains(id) else { return }
            failuresByID.removeValue(forKey: id)
            value.totalBytes -= preparedBytesByID.removeValue(forKey: id) ?? 0
            preparedOrder.removeAll { $0 == id }
            value.totalCount = preparedBytesByID.count
            value.failedCount = failuresByID.count
            value.failureCategories = Set(failuresByID.values)
        }
    }

    func beginUpload(currentIndex: Int, fileBytes: Int64) {
        beginUpload(
            id: nil,
            currentIndex: currentIndex,
            fileBytes: fileBytes
        )
    }

    func beginUpload(
        id: String?,
        currentIndex: Int,
        fileBytes: Int64
    ) {
        update { value in
            currentFileID = id
            value.stage = .uploading
            value.currentIndex = id.flatMap { preparedOrder.firstIndex(of: $0) }
                .map { $0 + 1 }
                ?? max(currentIndex, 1)
            value.totalCount = max(
                preparedBytesByID.count,
                value.currentIndex
            )
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
                if let currentFileID {
                    preparedBytesByID[currentFileID] = reportedTotal
                }
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
        let id = lock.withLock { currentFileID }
        finishCurrentFileUploaded(id: id, bytes: bytes)
    }

    func finishCurrentFileUploaded(id: String?, bytes: Int64) {
        update { value in
            if let id {
                uploadedIDs.insert(id)
                failuresByID.removeValue(forKey: id)
            }
            value.completedBytes = completedBytes()
            value.uploadedCount = uploadedIDs.count
            value.failedCount = failuresByID.count
            value.failureCategories = Set(failuresByID.values)
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
            currentFileID = nil
        }
    }

    func finishCurrentFileFailed(
        category: UploadErrorCategory,
        bytes: Int64
    ) {
        let id = lock.withLock { currentFileID }
        finishCurrentFileFailed(
            id: id,
            category: category,
            bytes: bytes
        )
    }

    func finishCurrentFileFailed(
        id: String?,
        category: UploadErrorCategory,
        bytes: Int64
    ) {
        update { value in
            if let id {
                let fileBytes = max(bytes, 0)
                if preparedBytesByID[id] == nil {
                    preparedBytesByID[id] = fileBytes
                    preparedOrder.append(id)
                    value.totalBytes += fileBytes
                }
                if !uploadedIDs.contains(id) {
                    failuresByID[id] = category
                }
            }
            value.totalCount = preparedBytesByID.count
            value.uploadedCount = uploadedIDs.count
            value.failedCount = failuresByID.count
            value.failureCategories = Set(failuresByID.values)
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
            currentFileID = nil
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
                preparedBytesByID.count,
                value.uploadedCount + value.failedCount
            )
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
            currentFileID = nil
            if value.failedCount == 0 {
                value.completedBytes = value.totalBytes
                value.stage = .completed
            } else {
                value.completedBytes = completedBytes()
                value.stage = .failed
            }
        }
    }

    func interrupt(category: UploadErrorCategory?) {
        update { value in
            value.uploadedCount = uploadedIDs.count
            value.failedCount = failuresByID.count
            value.totalCount = preparedBytesByID.count
            value.completedBytes = completedBytes()
            value.currentBytesSent = 0
            value.currentBytesTotal = 0
            currentFileID = nil
            value.failureCategories = Set(failuresByID.values)
            if let category {
                value.failureCategories.insert(category)
                value.stage = .failed
            } else {
                value.stage = .paused
            }
        }
    }

    private func completedBytes() -> Int64 {
        uploadedIDs.reduce(0) { result, id in
            result + (preparedBytesByID[id] ?? 0)
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
