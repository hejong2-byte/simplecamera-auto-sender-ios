import Foundation
import Photos

@MainActor
final class ContentViewModel: ObservableObject {
    typealias SendAction = @Sendable (SyncTrigger) async throws -> SyncTransferSummary
    typealias ManualEnqueueAction = @Sendable (
        ManualMediaSelection,
        ManualMediaKind
    ) async -> ManualMediaTransferSummary
    typealias ManualUpdatesAction = @Sendable () async -> AsyncStream<ManualTransferProgress>
    typealias AutomaticUpdatesAction = @Sendable () -> AsyncStream<AutomaticTransferProgress>

    @Published private(set) var photoAuthorizationStatus: PHAuthorizationStatus
    @Published private(set) var hasCredential = false
    @Published private(set) var isMonitoringEnabled = false
    @Published private(set) var queuedCount = 0
    @Published private(set) var uploadedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var automaticFailureMessage: String?
    @Published private(set) var lastSummary: SyncTransferSummary?
    @Published private(set) var lastError: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isManualTransferWorking = false
    @Published private(set) var lastManualSummary: ManualMediaTransferSummary?
    @Published private(set) var manualTransferMessage: String?
    @Published private(set) var manualProgress: ManualTransferProgress?
    @Published private(set) var automaticProgress: AutomaticTransferProgress?

    private let credentialStore: CredentialStore
    private let ledger: UploadLedger
    private let uploader: UploadCoordinating
    private let now: @Sendable () -> Date
    private let send: SendAction
    private let manualEnqueue: ManualEnqueueAction
    private var manualProgressTask: Task<Void, Never>?
    private var automaticProgressTask: Task<Void, Never>?

    init(
        credentialStore: CredentialStore,
        ledger: UploadLedger,
        uploader: UploadCoordinating,
        now: @escaping @Sendable () -> Date,
        send: @escaping SendAction,
        manualEnqueue: @escaping ManualEnqueueAction = { _, _ in .empty },
        manualUpdates: @escaping ManualUpdatesAction = {
            AsyncStream { continuation in continuation.finish() }
        },
        automaticUpdates: @escaping AutomaticUpdatesAction = {
            AsyncStream { continuation in continuation.finish() }
        },
        photoAuthorizationStatus initialPhotoAuthorizationStatus: PHAuthorizationStatus? = nil
    ) {
        self.credentialStore = credentialStore
        self.ledger = ledger
        self.uploader = uploader
        self.now = now
        self.send = send
        self.manualEnqueue = manualEnqueue
        photoAuthorizationStatus = initialPhotoAuthorizationStatus
            ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        manualProgressTask = Task { [weak self] in
            let updates = await manualUpdates()
            for await progress in updates {
                guard !Task.isCancelled else { break }
                self?.apply(progress)
            }
        }
        automaticProgressTask = Task { [weak self] in
            for await progress in automaticUpdates() {
                guard !Task.isCancelled else { break }
                self?.automaticProgress = progress
                if [.completed, .failed, .paused].contains(progress.stage) {
                    await self?.refresh()
                }
            }
        }
    }

    deinit {
        manualProgressTask?.cancel()
        automaticProgressTask?.cancel()
    }

    var hasFullPhotoAccess: Bool {
        photoAuthorizationStatus == .authorized
    }

    var manualTransferReadinessMessage: String? {
        if !hasFullPhotoAccess {
            return "설정에서 사진 전체 접근을 먼저 허용해 주세요."
        }
        if !hasCredential {
            return "설정에서 전송 인증값을 먼저 저장해 주세요."
        }
        if uploader.authenticationBlocked() {
            return "전송 인증이 거부되었습니다. 설정에서 인증값을 다시 저장해 주세요."
        }
        return nil
    }

    func refresh() async {
        photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        hasCredential = (try? credentialStore.load()) != nil
        isMonitoringEnabled = (try? await ledger.baseline()) != nil
        let records = await ledger.allRecords()
        queuedCount = records.filter { $0.state == .queued }.count
        uploadedCount = records.filter { $0.state == .uploaded }.count
        failedCount = records.filter { $0.state == .failed }.count
        automaticFailureMessage = Set(
            records.compactMap { record in
                record.state == .failed ? record.lastError : nil
            }
        ).uploadFailureDescription
    }

    func requestPhotoAccess() async {
        photoAuthorizationStatus = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func saveCredential(_ value: String) async throws {
        try credentialStore.save(value)
        uploader.credentialDidChange()
        hasCredential = true
        lastError = nil
    }

    func enableAutomaticSending() async throws {
        try await ledger.setBaseline(now())
        isMonitoringEnabled = true
        lastError = nil
    }

    func sendNow() async {
        await run(trigger: .manual)
    }

    func sendSelectedMedia(
        selection: ManualMediaSelection,
        kind: ManualMediaKind
    ) async {
        guard !isManualTransferWorking else { return }
        guard manualTransferReadinessMessage == nil else {
            manualTransferMessage = manualTransferReadinessMessage
            return
        }
        isManualTransferWorking = true
        manualTransferMessage = "\(selection.assetIdentifiers.count + selection.unavailableCount)개 항목 전송 중…"
        let summary = await manualEnqueue(selection, kind)
        lastManualSummary = summary
        if summary.selected == 0 || summary.failed == summary.selected {
            manualTransferMessage = Self.manualMessage(kind: kind, summary: summary)
            isManualTransferWorking = false
        } else {
            manualTransferMessage = "\(kind.title) 백그라운드 전송을 시작했습니다."
        }
        await refresh()
    }

    func retryFailed() async {
        await run(trigger: .retry)
    }

    func resetMonitoring() async {
        do {
            try await ledger.reset()
            isMonitoringEnabled = false
            lastSummary = nil
            lastError = nil
            await refresh()
        } catch {
            lastError = "자동 전송 정보를 초기화하지 못했습니다."
        }
    }

    private func run(trigger: SyncTrigger) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            lastSummary = try await send(trigger)
            lastError = nil
            await refresh()
        } catch UploadConfigurationError.missingCredential {
            lastError = "전송 인증값을 먼저 저장해 주세요."
        } catch UploadConfigurationError.authenticationBlocked {
            lastError = "인증이 거부되었습니다. 인증값을 다시 저장해 주세요."
        } catch PhotoSyncError.monitoringNotEnabled {
            lastError = "자동 전송 시작을 먼저 눌러 주세요."
        } catch {
            lastError = "사진 전송을 시작하지 못했습니다. 잠시 후 다시 시도해 주세요."
        }
    }

    private static func manualMessage(
        kind: ManualMediaKind,
        summary: ManualMediaTransferSummary
    ) -> String {
        guard summary.selected > 0 else { return "선택한 항목이 없습니다." }
        if summary.failed == 0 {
            return "\(kind.title): \(summary.uploaded)개 전송 완료"
        }
        var detail = "\(kind.title): \(summary.uploaded)개 완료, \(summary.failed)개 실패"
        if summary.failureCategories.contains(.tooLarge) {
            detail += " (2GiB 초과 파일 포함)"
        } else if summary.failureCategories.contains(.authentication) {
            detail += " (인증 설정 확인 필요)"
        } else if summary.failureCategories.contains(.network) {
            detail += " (네트워크 연결 확인 필요)"
        } else if summary.failureCategories.contains(.unsupported) {
            detail += " (지원하지 않는 형식 포함)"
        }
        return detail
    }

    var manualStageTitle: String {
        guard let progress = manualProgress else { return "수동 전송 상태" }
        switch progress.stage {
        case .idle: return "전송 대기"
        case .preparing: return "파일 준비 중"
        case .starting: return "백그라운드 전송 시작 중"
        case .uploading: return "PC로 전송 중"
        case .retrying: return "연결 재시도 중"
        case .verifying: return "서버 저장 확인 중"
        case .completed: return "전송 완료"
        case .failed: return "전송 실패"
        }
    }

    var manualByteProgressText: String {
        guard let progress = manualProgress else { return "" }
        return "\(Self.byteText(progress.displayedBytesSent)) / \(Self.byteText(progress.totalBytes))"
    }

    var automaticStageTitle: String {
        guard let progress = automaticProgress else {
            return "자동전송 대기"
        }
        let position = "\(progress.currentIndex)/\(progress.totalCount)장"
        switch progress.stage {
        case .idle: return "자동전송 대기"
        case .scanning: return "새 사진 확인 중"
        case .preparing:
            return "사진 조건 확인 중 · \(progress.candidateIndex)/\(progress.candidateCount)장"
        case .uploading: return "PC로 자동전송 중 · \(position)"
        case .verifying: return "서버 저장 확인 중 · \(position)"
        case .completed:
            return progress.uploadedCount == 0 ? "전송할 새 사진 없음" : "자동전송 완료"
        case .failed: return "자동전송 오류"
        case .paused: return "자동전송 일시중단"
        }
    }

    var automaticByteProgressText: String {
        guard let progress = automaticProgress else { return "" }
        return "\(Self.byteText(progress.displayedBytesSent)) / \(Self.byteText(progress.totalBytes))"
    }

    var automaticTransferMessage: String {
        guard let progress = automaticProgress else {
            return "Simple Cam을 닫으면 새 사진을 자동으로 전송합니다."
        }
        switch progress.stage {
        case .idle:
            return "Simple Cam을 닫으면 새 사진을 자동으로 전송합니다."
        case .scanning:
            return "Simple Cam으로 촬영한 새 사진을 확인하고 있습니다."
        case .preparing:
            return "해상도와 iPhone 표시를 확인 중입니다. 조건에 맞는 사진만 전송합니다."
        case .uploading:
            return "\(progress.uploadedCount)장 완료 · \(progress.failedCount)장 실패"
        case .verifying:
            return "PC 수신 서버의 저장 응답을 확인하고 있습니다."
        case .completed:
            return progress.uploadedCount == 0
                ? "전송할 새 Simple Cam 사진이 없습니다."
                : "자동전송 완료 · \(progress.uploadedCount)장"
        case .failed:
            let reason = progress.failureCategories.uploadFailureDescription
                ?? "알 수 없는 오류"
            return "자동전송 실패 포함 · \(reason)"
        case .paused:
            return "\(progress.uploadedCount)장 완료 · 남은 사진은 다음 자동실행 때 다시 전송합니다."
        }
    }

    private func apply(_ progress: ManualTransferProgress) {
        manualProgress = progress
        let categories: Set<ManualTransferFailureCategory>
        switch progress.failure {
        case .network?: categories = [.network]
        case .authentication?: categories = [.authentication]
        case .server?: categories = [.server]
        case .unsupported?: categories = [.unsupported]
        case .tooLarge?: categories = [.tooLarge]
        case .other?: categories = [.other]
        case nil: categories = []
        }
        lastManualSummary = ManualMediaTransferSummary(
            selected: progress.selectedCount,
            uploaded: progress.uploadedCount,
            failed: progress.failedCount,
            failureCategories: categories
        )
        isManualTransferWorking = progress.completedCount < progress.selectedCount
            || Self.activeManualStages.contains(progress.stage)
        manualTransferMessage = Self.progressMessage(progress)
    }

    private static let activeManualStages: Set<ManualTransferStage> = [
        .preparing,
        .starting,
        .uploading,
        .retrying,
        .verifying,
    ]

    private static func progressMessage(_ progress: ManualTransferProgress) -> String {
        switch progress.stage {
        case .idle:
            return "전송할 종류를 선택하세요."
        case .preparing:
            return "\(progress.kind.title) 준비 중 · \(progress.currentIndex)/\(progress.selectedCount)"
        case .starting:
            return "\(progress.kind.title) 백그라운드 시작 중"
        case .uploading:
            return "\(progress.kind.title) 중 · \(progress.percent)%"
        case .retrying:
            return "\(progress.kind.title) 재시도 중 · \(progress.retryAttempt)/3"
        case .verifying:
            return "\(progress.kind.title) 저장 확인 중 · \(progress.percent)%"
        case .completed:
            return "\(progress.kind.title) 완료 · \(progress.uploadedCount)개"
        case .failed:
            return failureMessage(progress)
        }
    }

    private static func failureMessage(_ progress: ManualTransferProgress) -> String {
        let prefix = "\(progress.kind.title) 실패"
        switch progress.failure {
        case .network?:
            return prefix + " · 네트워크 연결을 확인해 주세요."
        case .authentication?:
            return prefix + " · 전송 인증 설정을 확인해 주세요."
        case let .server(statusCode, code)?:
            let detail: String
            switch code {
            case "size_mismatch": detail = "서버 크기 검증 실패"
            case "id_mismatch": detail = "서버 파일 식별 검증 실패"
            case "metadata_missing": detail = "서버 파일 정보 검증 실패"
            default: detail = "서버 오류"
            }
            return prefix + " · \(detail) (HTTP \(statusCode))"
        case .unsupported?:
            return prefix + " · 지원하지 않는 형식입니다."
        case .tooLarge?:
            return prefix + " · 2GiB를 초과한 파일입니다."
        case .other?, nil:
            return prefix + " · 파일을 전송하지 못했습니다."
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        let value = max(bytes, 0)
        if value < 1_024 { return "\(value)바이트" }
        if value < 1_024 * 1_024 {
            return String(format: "%.1fKB", Double(value) / 1_024)
        }
        if value < 1_024 * 1_024 * 1_024 {
            return String(format: "%.1fMB", Double(value) / Double(1_024 * 1_024))
        }
        return String(format: "%.2fGB", Double(value) / Double(1_024 * 1_024 * 1_024))
    }
}
