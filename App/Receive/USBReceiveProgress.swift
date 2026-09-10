import Foundation

enum USBReceiveStage: String, Codable, Sendable, Equatable {
    case idle
    case discovering
    case waitingForDestination
    case downloading
    case downloaded
    case extracting
    case verifying
    case finalizing
    case copyingToUSB
    case acknowledging
    case receiptPending
    case savedWithoutReceipt
    case checkingSource
    case completed
    case paused
    case cancelled
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
    let detail: String?
    let sourceFileIDs: [String]?
    let archiveMode: IPhoneReceiveArchiveMode?

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
        errorMessage: String?,
        detail: String? = nil,
        sourceFileIDs: [String]? = nil,
        archiveMode: IPhoneReceiveArchiveMode? = nil
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
        self.detail = detail
        self.sourceFileIDs = sourceFileIDs
        self.archiveMode = archiveMode
    }

    var percent: Int {
        guard totalBytes > 0 else {
            return [
                .extracting, .verifying, .finalizing, .copyingToUSB,
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
    private let fileURL: URL?
    private var lastSavedAt: Date?
    private var interruption: USBReceiveProgress?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(USBReceiveProgress.self, from: Data(contentsOf: fileURL))
            latest = Self.isInFlight(saved.stage)
                ? Self.paused(saved, message: "이전 USB 복사가 중단되었습니다. 완료된 복사본이 아닙니다. 같은 파일을 다시 USB로 복사하면 남은 부분부터 이어받습니다. 임시파일 정리는 이어받기를 포기할 때만 실행해 주세요. 원본 ZIP은 유지됩니다.")
                : saved
        } catch {
            latest = USBReceiveProgress(stage: .failed, deliveryID: nil, fileName: nil,
                currentIndex: 0, totalCount: 0, completedCount: 0, bytesReceived: 0,
                totalBytes: 0, startedAt: nil, expiresAt: nil,
                errorMessage: "이전 USB 복사 기록을 읽지 못했습니다. USB 상태를 확인해 주세요. 원본 파일은 삭제하지 않았습니다.")
        }
    }

    func beginExport(
        fileName: String?,
        totalCount: Int,
        sourceFileIDs: [String] = [],
        archiveMode: IPhoneReceiveArchiveMode? = nil
    ) {
        lock.withLock { interruption = nil }
        publish(USBReceiveProgress(stage: .checkingSource, deliveryID: nil, fileName: fileName,
            currentIndex: 1, totalCount: totalCount, completedCount: 0, bytesReceived: 0,
            totalBytes: 0, startedAt: Date(), expiresAt: nil, errorMessage: nil,
            detail: "USB 복사 준비 중", sourceFileIDs: sourceFileIDs,
            archiveMode: archiveMode))
    }

    func interruptExport() {
        let paused = lock.withLock { () -> USBReceiveProgress in
            let value = Self.paused(latest, message: "백그라운드 실행 시간이 끝나 USB 복사가 중단되었습니다. 앱으로 돌아오면 자동으로 이어받으며, 앱이 다시 실행된 경우 같은 파일을 USB로 복사하면 남은 부분부터 이어받습니다. 원본 ZIP은 유지됩니다.")
            interruption = value
            return value
        }
        publish(paused)
    }

    private static func isInFlight(_ stage: USBReceiveStage) -> Bool {
        [.checkingSource, .extracting, .copyingToUSB, .verifying, .finalizing].contains(stage)
    }

    private static func paused(_ value: USBReceiveProgress, message: String) -> USBReceiveProgress {
        USBReceiveProgress(stage: .paused, destination: value.destination, deliveryID: value.deliveryID,
            fileName: value.fileName, currentIndex: value.currentIndex, totalCount: value.totalCount,
            completedCount: value.completedCount, bytesReceived: value.bytesReceived,
            totalBytes: value.totalBytes, startedAt: nil, expiresAt: nil, errorMessage: nil,
            detail: [value.detail, message].compactMap { $0 }.joined(separator: "\n"),
            sourceFileIDs: value.sourceFileIDs, archiveMode: value.archiveMode)
    }

    // Small local checkpoints, at most once a second while bytes advance. Stage
    // changes and interruption are always flushed; no USB I/O is performed here.
    private func persistLocked(force: Bool) {
        guard let fileURL else { return }
        let now = Date()
        guard force || lastSavedAt.map({ now.timeIntervalSince($0) >= 1 }) != false else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(latest).write(to: fileURL, options: .atomic)
            lastSavedAt = now
        } catch {
            // Preserve the live progress, but don't silently claim restart recovery.
            latest = USBReceiveProgress(stage: latest.stage, destination: latest.destination,
                deliveryID: latest.deliveryID, fileName: latest.fileName,
                currentIndex: latest.currentIndex, totalCount: latest.totalCount,
                completedCount: latest.completedCount, bytesReceived: latest.bytesReceived,
                totalBytes: latest.totalBytes, startedAt: latest.startedAt, expiresAt: latest.expiresAt,
                errorMessage: latest.errorMessage,
                detail: "USB 복사 진행 기록 저장 실패 · 앱을 종료하면 진행 표시를 복원하지 못할 수 있습니다.",
                sourceFileIDs: latest.sourceFileIDs, archiveMode: latest.archiveMode)
        }
    }

    func snapshot() -> USBReceiveProgress {
        lock.withLock { latest }
    }

    func publish(_ progress: USBReceiveProgress) {
        var delivered = progress
        let current = lock.withLock { () -> [
            AsyncStream<USBReceiveProgress>.Continuation
        ] in
            let oldStage = latest.stage
            if let interruption, progress.stage != .completed && progress.stage != .failed {
                delivered = interruption
            }
            latest = delivered
            persistLocked(force: oldStage != latest.stage || latest.stage == .paused)
            delivered = latest
            return Array(continuations.values)
        }
        current.forEach { _ = $0.yield(delivered) }
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
                errorMessage: message,
                sourceFileIDs: latest.sourceFileIDs,
                archiveMode: latest.archiveMode
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

    func clearInterruptedExport() {
        clear { $0.stage == .paused }
    }

    private func clear(where shouldClear: (USBReceiveProgress) -> Bool) {
        let current = lock.withLock { () -> [AsyncStream<USBReceiveProgress>.Continuation] in
            guard shouldClear(latest) else { return [] }
            latest = .idle
            interruption = nil
            persistLocked(force: true)
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
