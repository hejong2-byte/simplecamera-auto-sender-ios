import Foundation

enum USBReceiveStage: String, Codable, Sendable, Equatable {
    case idle
    case discovering
    case waitingForDestination
    case downloading
    case downloaded
    case verifying
    case finalizing
    case copyingToUSB
    case acknowledging
    case completed
    case paused
    case failed
}

enum IPhoneReceiveDestination: String, Codable, CaseIterable, Sendable, Equatable {
    case iphoneLocal
    case usb
}

struct USBReceiveProgress: Codable, Sendable, Equatable {
    let stage: USBReceiveStage
    let destination: IPhoneReceiveDestination
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

    init(
        stage: USBReceiveStage,
        destination: IPhoneReceiveDestination = .usb,
        deliveryID: UUID?,
        fileName: String?,
        currentIndex: Int,
        totalCount: Int,
        completedCount: Int,
        bytesReceived: Int64,
        totalBytes: Int64,
        startedAt: Date?,
        expiresAt: Date?,
        errorMessage: String?
    ) {
        self.stage = stage
        self.destination = destination
        self.deliveryID = deliveryID
        self.fileName = fileName
        self.currentIndex = currentIndex
        self.totalCount = totalCount
        self.completedCount = completedCount
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.errorMessage = errorMessage
    }

    var percent: Int {
        guard totalBytes > 0 else {
            return [
                .verifying, .finalizing, .copyingToUSB,
                .acknowledging, .completed
            ].contains(stage) ? 100 : 0
        }
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
                destination: latest.destination,
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

    func clearDiscoveryFailure() {
        clear { $0.stage == .failed && $0.deliveryID == nil }
    }

    func publishDiscoveryFailure(_ message: String, destination: IPhoneReceiveDestination) {
        let failure = USBReceiveProgress(
            stage: .failed,
            destination: destination,
            deliveryID: nil,
            fileName: nil,
            currentIndex: 0,
            totalCount: 0,
            completedCount: 0,
            bytesReceived: 0,
            totalBytes: 0,
            startedAt: nil,
            expiresAt: nil,
            errorMessage: message
        )
        let current = lock.withLock { () -> [AsyncStream<USBReceiveProgress>.Continuation] in
            guard latest.stage != .failed || latest.deliveryID == nil else { return [] }
            latest = failure
            return Array(continuations.values)
        }
        current.forEach { _ = $0.yield(failure) }
    }

    func clearCompleted() {
        clear { $0.stage == .completed }
    }

    private func clear(where shouldClear: (USBReceiveProgress) -> Bool) {
        let current = lock.withLock { () -> [AsyncStream<USBReceiveProgress>.Continuation] in
            guard shouldClear(latest) else { return [] }
            latest = .idle
            return Array(continuations.values)
        }
        current.forEach { _ = $0.yield(.idle) }
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
