import Foundation

enum USBReceiveStage: String, Codable, Sendable, Equatable {
    case idle
    case discovering
    case downloading
    case verifying
    case finalizing
    case acknowledging
    case completed
    case failed
}

struct USBReceiveProgress: Codable, Sendable, Equatable {
    let stage: USBReceiveStage
    let deliveryID: UUID?
    let fileName: String?
    let currentIndex: Int
    let totalCount: Int
    let completedCount: Int
    let bytesReceived: Int64
    let totalBytes: Int64
    let startedAt: Date?
    let expiresAt: Date?
    let errorMessage: String?

    var percent: Int {
        guard totalBytes > 0 else { return stage == .completed ? 100 : 0 }
        return min(
            100,
            max(0, Int(Double(bytesReceived) / Double(totalBytes) * 100))
        )
    }

    static var idle: Self {
        Self(
            stage: .idle,
            deliveryID: nil,
            fileName: nil,
            currentIndex: 0,
            totalCount: 0,
            completedCount: 0,
            bytesReceived: 0,
            totalBytes: 0,
            startedAt: nil,
            expiresAt: nil,
            errorMessage: nil
        )
    }
}

final class USBReceiveProgressStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = USBReceiveProgress.idle
    private var continuations: [UUID: AsyncStream<USBReceiveProgress>.Continuation] = [:]

    func publish(_ progress: USBReceiveProgress) {
        let current = lock.withLock { () -> [
            AsyncStream<USBReceiveProgress>.Continuation
        ] in
            latest = progress
            return Array(continuations.values)
        }
        current.forEach { _ = $0.yield(progress) }
    }

    func publishFailure(_ message: String) {
        let failure = lock.withLock { () -> USBReceiveProgress in
            USBReceiveProgress(
                stage: .failed,
                deliveryID: latest.deliveryID,
                fileName: latest.fileName,
                currentIndex: latest.currentIndex,
                totalCount: latest.totalCount,
                completedCount: latest.completedCount,
                bytesReceived: latest.bytesReceived,
                totalBytes: latest.totalBytes,
                startedAt: latest.startedAt,
                expiresAt: latest.expiresAt,
                errorMessage: message
            )
        }
        publish(failure)
    }

    func updates() -> AsyncStream<USBReceiveProgress> {
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
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
}
