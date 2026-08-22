import Foundation
import Photos

@MainActor
final class ContentViewModel: ObservableObject {
    typealias SendAction = @Sendable (SyncTrigger) async throws -> SyncTransferSummary
    typealias ManualSendAction = @Sendable (
        ManualMediaSelection,
        ManualMediaKind
    ) async -> ManualMediaTransferSummary

    @Published private(set) var photoAuthorizationStatus: PHAuthorizationStatus
    @Published private(set) var hasCredential = false
    @Published private(set) var isMonitoringEnabled = false
    @Published private(set) var queuedCount = 0
    @Published private(set) var uploadedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var lastSummary: SyncTransferSummary?
    @Published private(set) var lastError: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isManualTransferWorking = false
    @Published private(set) var lastManualSummary: ManualMediaTransferSummary?
    @Published private(set) var manualTransferMessage: String?

    private let credentialStore: CredentialStore
    private let ledger: UploadLedger
    private let uploader: UploadCoordinating
    private let now: @Sendable () -> Date
    private let send: SendAction
    private let manualSend: ManualSendAction

    init(
        credentialStore: CredentialStore,
        ledger: UploadLedger,
        uploader: UploadCoordinating,
        now: @escaping @Sendable () -> Date,
        send: @escaping SendAction,
        manualSend: @escaping ManualSendAction = { _, _ in .empty },
        photoAuthorizationStatus initialPhotoAuthorizationStatus: PHAuthorizationStatus? = nil
    ) {
        self.credentialStore = credentialStore
        self.ledger = ledger
        self.uploader = uploader
        self.now = now
        self.send = send
        self.manualSend = manualSend
        photoAuthorizationStatus = initialPhotoAuthorizationStatus
            ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
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
        let summary = await manualSend(selection, kind)
        lastManualSummary = summary
        manualTransferMessage = Self.manualMessage(kind: kind, summary: summary)
        isManualTransferWorking = false
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
}
