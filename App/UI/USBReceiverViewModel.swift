import Foundation
import QuickLook

enum IPhoneReceiveStatusKind: Sendable, Equatable {
    case waiting
    case active
    case saved
    case failed
}

struct IPhoneReceiveStatus: Sendable, Equatable {
    let kind: IPhoneReceiveStatusKind
    let title: String
    let message: String
    let fileName: String?
    let occurredAt: Date?
    let percent: Int?
}

@MainActor
final class USBReceiverViewModel: ObservableObject {
    typealias ReceiveOnce = @Sendable () async throws -> USBReceiveSummary
    typealias ReceiveLocalOnce = @Sendable () async throws -> Void
    typealias PendingDeliveryIDs = @Sendable () async throws -> Set<UUID>
    typealias ApproveLocalFallback = @Sendable (Set<UUID>) throws -> Void
    typealias StoredFilesProvider = @Sendable () throws -> [IPhoneStoredFile]
    typealias StoredFilePreviewAction = @Sendable (IPhoneStoredFile) throws -> URL
    typealias DeleteStoredFiles = @Sendable ([IPhoneStoredFile]) async throws -> IPhoneStoredFileDeletionSummary
    typealias ExportFiles = @Sendable (
        [IPhoneStoredFile],
        USBBookmarkDestination
    ) async -> IPhoneUSBExportSummary
    typealias PendingDeletionDecisions = @Sendable () -> [IPhoneUSBDeletionDecision]
    typealias KeepOriginals = @Sendable (Set<UUID>) async throws -> Void
    typealias DeleteOriginals = @Sendable (Set<UUID>) async -> IPhoneUSBDeletionSummary
    typealias RefreshFeatures = @Sendable () async throws -> Void
    typealias ProgressUpdates = @Sendable () -> AsyncStream<USBReceiveProgress>
    typealias LoadOutcome = @Sendable (UUID) -> IPhoneReceiveOutcome?
    typealias SaveOutcome = @Sendable (IPhoneReceiveOutcome) throws -> Void
    typealias ClearOutcome = @Sendable (UUID) throws -> Void
    typealias Now = @Sendable () -> Date
    typealias Sleep = @Sendable () async throws -> Void

    @Published private(set) var registrationCode: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var usbDisplayName: String?
    @Published private(set) var receiveProgress: USBReceiveProgress?
    @Published private(set) var receiveOutcome: IPhoneReceiveOutcome?
    @Published private(set) var usbExportProgress: USBReceiveProgress?
    @Published private(set) var lastUSBExportError: String?
    @Published private(set) var usbExportCompletionMessage: String?
    @Published private(set) var lastOriginalCleanupError: String?
    @Published private(set) var isExportingToUSB = false
    @Published private(set) var isPolling = false
    @Published private(set) var lastError: String?
    @Published private(set) var allowsCellular: Bool
    @Published private(set) var selectedDestination: IPhoneReceiveDestination
    @Published private(set) var storedFiles: [IPhoneStoredFile] = []
    @Published private(set) var selectedStoredFileIDs: Set<String> = []
    @Published private(set) var storedFilesPendingDeletion: [IPhoneStoredFile] = []
    @Published private(set) var isDeletingStoredFiles = false
    @Published private(set) var storedFileDeletionMessage: String?
    @Published private(set) var storedFileDeletionError: String?
    @Published var previewFile: IPhoneStoredFile?
    @Published var storedFilePreviewError: String?
    @Published private(set) var needsLocalFallbackDecision = false
    @Published private(set) var needsDeletionDecision = false
    @Published var isChoosingUSBFolder = false
    @Published var isShowingSettingsConfirmation = false
    @Published private(set) var isPerformingReceive = false

    private enum USBFallbackMode {
        case none
        case serverWait(Set<UUID>)
    }

    private let uploadCredentialStore: CredentialStore
    private let registrationStore: IPhoneReceiverRegistrationStore
    private let bookmarkStore: USBBookmarkStore
    private let registrar: any IPhoneReceiverRegistering
    private let receiveOnce: ReceiveOnce
    private let receiveLocalOnce: ReceiveLocalOnce
    private let pendingDeliveryIDs: PendingDeliveryIDs
    private let approveLocalFallback: ApproveLocalFallback
    private let storedFilesProvider: StoredFilesProvider
    private let previewStoredFile: StoredFilePreviewAction
    private let canPreviewFile: @MainActor (URL) -> Bool
    private let deleteStoredFiles: DeleteStoredFiles
    private let exportFiles: ExportFiles
    private let pendingDeletionDecisions: PendingDeletionDecisions
    private let keepOriginalFiles: KeepOriginals
    private let deleteOriginalFiles: DeleteOriginals
    private let refreshFeatures: RefreshFeatures
    private let loadOutcome: LoadOutcome
    private let saveOutcome: SaveOutcome
    private let clearOutcome: ClearOutcome
    private let now: Now
    private let defaultDeviceName: String
    private let sleep: Sleep
    private let preferences: USBReceiverPreferences
    private var progressTask: Task<Void, Never>?
    private var exportProgressTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var fallbackMode: USBFallbackMode = .none
    private var promptedDeliveryIDs: Set<UUID> = []
    private var receiverID: UUID?

    init(
        uploadCredentialStore: CredentialStore,
        registrationStore: IPhoneReceiverRegistrationStore,
        bookmarkStore: USBBookmarkStore,
        registrar: any IPhoneReceiverRegistering,
        receiveOnce: @escaping ReceiveOnce,
        receiveLocalOnce: @escaping ReceiveLocalOnce = {},
        pendingDeliveryIDs: @escaping PendingDeliveryIDs = { [] },
        approveLocalFallback: @escaping ApproveLocalFallback = { _ in },
        storedFiles: @escaping StoredFilesProvider = { [] },
        previewStoredFile: @escaping StoredFilePreviewAction = { _ in
            throw IPhoneStoredFilePreviewError.unavailable
        },
        canPreviewFile: @escaping @MainActor (URL) -> Bool = { QLPreviewController.canPreview($0 as NSURL) },
        deleteStoredFiles: @escaping DeleteStoredFiles = { _ in
            throw CocoaError(.featureUnsupported)
        },
        exportFiles: @escaping ExportFiles = { _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        },
        pendingDeletionDecisions: @escaping PendingDeletionDecisions = { [] },
        keepOriginals: @escaping KeepOriginals = { _ in },
        deleteOriginals: @escaping DeleteOriginals = { _ in
            IPhoneUSBDeletionSummary(deletedSourceIDs: [], failed: [])
        },
        refreshFeatures: @escaping RefreshFeatures = {},
        progressUpdates: @escaping ProgressUpdates,
        exportProgressUpdates: @escaping ProgressUpdates = { AsyncStream { $0.finish() } },
        loadOutcome: @escaping LoadOutcome = { _ in nil },
        saveOutcome: @escaping SaveOutcome = { _ in },
        clearOutcome: @escaping ClearOutcome = { _ in },
        now: @escaping Now = { Date() },
        defaultDeviceName: String,
        preferences: USBReceiverPreferences = USBReceiverPreferences(),
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds(2)) }
    ) {
        self.uploadCredentialStore = uploadCredentialStore
        self.registrationStore = registrationStore
        self.bookmarkStore = bookmarkStore
        self.registrar = registrar
        self.receiveOnce = receiveOnce
        self.receiveLocalOnce = receiveLocalOnce
        self.pendingDeliveryIDs = pendingDeliveryIDs
        self.approveLocalFallback = approveLocalFallback
        self.storedFilesProvider = storedFiles
        self.previewStoredFile = previewStoredFile
        self.canPreviewFile = canPreviewFile
        self.deleteStoredFiles = deleteStoredFiles
        self.exportFiles = exportFiles
        self.pendingDeletionDecisions = pendingDeletionDecisions
        self.keepOriginalFiles = keepOriginals
        self.deleteOriginalFiles = deleteOriginals
        self.refreshFeatures = refreshFeatures
        self.loadOutcome = loadOutcome
        self.saveOutcome = saveOutcome
        self.clearOutcome = clearOutcome
        self.now = now
        self.defaultDeviceName = defaultDeviceName
        self.preferences = preferences
        allowsCellular = preferences.allowsCellular
        selectedDestination = preferences.selectedDestination
        self.sleep = sleep
        progressTask = Task { [weak self] in
            for await progress in progressUpdates() {
                guard !Task.isCancelled else { break }
                self?.handleReceiveProgress(progress)
            }
        }
        exportProgressTask = Task { [weak self] in
            for await progress in exportProgressUpdates() {
                guard !Task.isCancelled else { break }
                self?.usbExportProgress = progress.stage == .idle ? nil : progress
                if progress.stage == .failed {
                    self?.lastUSBExportError = progress.errorMessage
                }
            }
        }
    }

    deinit {
        progressTask?.cancel()
        exportProgressTask?.cancel()
        pollingTask?.cancel()
    }

    var isRegistered: Bool { registrationCode != nil }
    var hasUSBDestination: Bool { usbDisplayName != nil }
    var hasStoredFileSelection: Bool { !selectedStoredFileIDs.isEmpty }
    var needsStoredFileDeletionConfirmation: Bool { !storedFilesPendingDeletion.isEmpty }
    var canDeleteStoredFiles: Bool {
        hasStoredFileSelection && !isDeletingStoredFiles
    }
    var pendingDeletionCount: Int { pendingDeletionDecisions().count }
    var isReceivingFile: Bool {
        guard let stage = receiveProgress?.stage else { return false }
        return (isPerformingReceive || receiveProgress?.destination == .iphoneLocal)
            && [
                .discovering, .waitingForDestination, .downloading, .downloaded,
                .verifying, .finalizing, .copyingToUSB, .acknowledging
            ].contains(stage)
    }

    var receiveStatus: IPhoneReceiveStatus {
        if isReceivingFile, let progress = receiveProgress {
            let message: String
            switch progress.stage {
            case .discovering:
                message = "PC에서 새 파일을 확인하고 있습니다."
            case .waitingForDestination:
                message = "저장 위치를 선택해 주세요."
            default:
                message = progress.fileName ?? "파일을 안전하게 처리하고 있습니다."
            }
            return IPhoneReceiveStatus(
                kind: .active,
                title: receiveStageTitle,
                message: message,
                fileName: progress.fileName,
                occurredAt: nil,
                percent: progress.totalBytes > 0 ? progress.percent : nil
            )
        }

        if let outcome = receiveOutcome {
            let destination = outcome.destination == .iphoneLocal ? "iPhone" : "USB"
            switch outcome.kind {
            case .saved:
                let count = max(outcome.totalCount, outcome.completedCount)
                let message = count > 0
                    ? "\(outcome.completedCount)/\(count)개 파일을 안전하게 저장했습니다."
                    : "파일을 안전하게 저장했습니다."
                return IPhoneReceiveStatus(
                    kind: .saved,
                    title: outcome.message,
                    message: message,
                    fileName: outcome.fileName,
                    occurredAt: outcome.occurredAt,
                    percent: 100
                )
            case .failed:
                return IPhoneReceiveStatus(
                    kind: .failed,
                    title: outcome.fileName == nil
                        ? "새 파일 확인 오류"
                        : "\(destination) 수신 오류",
                    message: outcome.message,
                    fileName: outcome.fileName,
                    occurredAt: outcome.occurredAt,
                    percent: nil
                )
            }
        }

        return IPhoneReceiveStatus(
            kind: .waiting,
            title: isRegistered ? "PC 파일 수신 대기" : "수신 기기 등록 필요",
            message: isRegistered
                ? "PC에서 보내면 이 앱이 새 파일을 확인합니다."
                : "설정에서 PC 파일 수신을 등록해 주세요.",
            fileName: nil,
            occurredAt: nil,
            percent: nil
        )
    }

    func openStoredFile(_ file: IPhoneStoredFile) {
        do {
            let url = try previewStoredFile(file)
            guard canPreviewFile(url) else { throw IPhoneStoredFilePreviewError.unsupported }
            previewFile = file
            storedFilePreviewError = nil
        } catch {
            previewFile = nil
            if let files = try? storedFilesProvider() {
                storedFiles = files
                selectedStoredFileIDs.formIntersection(Set(files.map(\.id)))
            }
            storedFilePreviewError = error.localizedDescription
        }
    }

    func refresh() async {
        do {
            storedFiles = try storedFilesProvider()
            selectedStoredFileIDs.formIntersection(Set(storedFiles.map(\.id)))
            needsDeletionDecision = !pendingDeletionDecisions().isEmpty
        } catch {
            lastError = Self.message(for: error)
        }

        do {
            let registration = try registrationStore.load()
            receiverID = registration?.identity.receiverID
            registrationCode = registration?.identity.code
            deviceName = registration?.identity.deviceName
            if let registration {
                let outcome = loadOutcome(registration.identity.receiverID)
                if let outcome,
                   outcome.kind == .failed,
                   IPhoneReceiveErrorMessage.isCancellationMessage(outcome.message) {
                    try clearOutcome(registration.identity.receiverID)
                    receiveOutcome = nil
                } else {
                    receiveOutcome = outcome
                }
            } else {
                receiveOutcome = nil
            }
            let destination = try bookmarkStore.resolve()
            usbDisplayName = destination?.displayName
            if selectedDestination == .usb, destination?.isStale == true {
                lastError = "USB 폴더 권한이 만료되었습니다. 폴더를 다시 선택해 주세요."
            }
            if registration != nil { try await refreshFeatures() }
        } catch let error where IPhoneReceiveErrorMessage.isCancellation(error) {
            return
        } catch {
            lastError = Self.message(for: error)
        }
    }

    func registerDevice() async {
        do {
            guard let uploadCredential = try uploadCredentialStore.load() else {
                lastError = "먼저 설정에서 전송 인증값을 저장해 주세요."
                return
            }
            let registration = try await registrar.register(
                uploadCredential: uploadCredential,
                deviceName: defaultDeviceName
            )
            try registrationStore.save(registration)
            receiverID = registration.receiverID
            registrationCode = registration.code
            deviceName = registration.deviceName
            receiveOutcome = loadOutcome(registration.receiverID)
            try await refreshFeatures()
            lastError = nil
        } catch {
            lastError = "iPhone 수신 기기를 등록하지 못했습니다."
        }
    }

    func setSelectedDestination(_ destination: IPhoneReceiveDestination) {
        preferences.selectedDestination = destination
        selectedDestination = destination
        resetFallback()
        lastError = nil
    }

    func selectDestination(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try bookmarkStore.save(folderURL: url)
            let destination = try bookmarkStore.resolve()
            usbDisplayName = destination?.displayName
            lastError = destination?.isStale == true
                ? "USB 폴더 권한이 만료되었습니다. 다시 선택해 주세요."
                : nil
            if destination != nil, destination?.isStale == false { resetFallback() }
        } catch {
            lastError = "선택한 USB 폴더를 저장하지 못했습니다."
        }
    }

    func clearDestination() async {
        do {
            try bookmarkStore.clear()
            usbDisplayName = nil
            lastError = nil
        } catch {
            lastError = "USB 폴더 설정을 지우지 못했습니다."
        }
    }

    func resetRegistration() async {
        do {
            let matchingReceiverID: UUID?
            if let receiverID {
                matchingReceiverID = receiverID
            } else {
                matchingReceiverID = try registrationStore.load()?.identity.receiverID
            }
            if let matchingReceiverID {
                try clearOutcome(matchingReceiverID)
            }
            try registrationStore.clear()
            receiverID = nil
            registrationCode = nil
            deviceName = nil
            receiveOutcome = nil
            lastError = nil
        } catch {
            lastError = "수신 기기 등록을 초기화하지 못했습니다."
        }
    }

    func startForegroundPolling() {
        guard pollingTask == nil else { return }
        isPolling = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await pollOnce()
                do { try await sleep() } catch { return }
            }
        }
    }

    func pollOnce() async {
        guard !isExportingToUSB, !isPerformingReceive, !isChoosingUSBFolder,
              !needsLocalFallbackDecision, !needsDeletionDecision,
              !isDeletingStoredFiles, !needsStoredFileDeletionConfirmation else { return }
        isPerformingReceive = true
        defer { isPerformingReceive = false }
        do {
            switch selectedDestination {
            case .iphoneLocal:
                try await receiveLocalOnce()
            case .usb:
                try await pollUSB()
            }
            if receiveProgress?.stage != .failed,
               !needsLocalFallbackDecision {
                lastError = nil
            }
        } catch let error where IPhoneReceiveErrorMessage.isCancellation(error) {
            return
        } catch {
            lastError = Self.message(for: error)
        }
    }

    func chooseLocalFallback() async {
        guard !promptedDeliveryIDs.isEmpty else { return }
        do {
            try approveLocalFallback(promptedDeliveryIDs)
            setSelectedDestination(.iphoneLocal)
            try await receiveLocalOnce()
        } catch { lastError = Self.message(for: error) }
    }

    func chooseServerWait() async {
        guard !promptedDeliveryIDs.isEmpty else { return }
        fallbackMode = .serverWait(promptedDeliveryIDs)
        needsLocalFallbackDecision = false
        lastError = "현재 파일은 서버에 그대로 대기합니다."
    }

    func stopForegroundPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    func setAllowsCellular(_ allowed: Bool) {
        preferences.allowsCellular = allowed
        allowsCellular = allowed
    }

    func toggleStoredFileSelection(_ id: String) {
        guard !isDeletingStoredFiles, !needsStoredFileDeletionConfirmation else { return }
        if selectedStoredFileIDs.contains(id) {
            selectedStoredFileIDs.remove(id)
        } else {
            selectedStoredFileIDs.insert(id)
        }
    }

    func requestStoredFileDeletion() {
        guard canDeleteStoredFiles, !needsStoredFileDeletionConfirmation,
              !isChoosingUSBFolder, !needsDeletionDecision,
              !needsLocalFallbackDecision else { return }
        guard !isReceivingFile, !isExportingToUSB else {
            storedFileDeletionError = "전송 중에는 삭제할 수 없습니다. 전송이 끝난 뒤 다시 눌러 주세요."
            return
        }
        storedFileDeletionError = nil
        storedFilesPendingDeletion = storedFiles.filter { selectedStoredFileIDs.contains($0.id) }
    }

    func cancelStoredFileDeletion() {
        storedFilesPendingDeletion = []
    }

    func deleteConfirmedStoredFiles() async {
        guard !storedFilesPendingDeletion.isEmpty, !isDeletingStoredFiles else { return }
        guard !isReceivingFile, !isExportingToUSB else {
            storedFilesPendingDeletion = []
            storedFileDeletionError = "전송 중에는 삭제할 수 없습니다. 전송이 끝난 뒤 다시 눌러 주세요."
            return
        }
        let confirmedFiles = storedFilesPendingDeletion
        storedFilesPendingDeletion = []
        isDeletingStoredFiles = true
        storedFileDeletionMessage = nil
        storedFileDeletionError = nil
        defer { isDeletingStoredFiles = false }
        do {
            let summary = try await deleteStoredFiles(confirmedFiles)
            let deletedIDs = Set(summary.deletedIDs)
            selectedStoredFileIDs.subtract(deletedIDs)
            storedFiles.removeAll { deletedIDs.contains($0.id) }
            if !deletedIDs.isEmpty {
                storedFileDeletionMessage = "iPhone 파일 \(deletedIDs.count)개 삭제 완료"
            }
            if let failure = summary.failures.first {
                storedFileDeletionError = "\(summary.failures.count)개 삭제 실패 · \(failure.name)\n\(failure.message)"
            }
        } catch {
            storedFileDeletionError = "파일을 삭제하지 못했습니다. \(error.localizedDescription)"
        }
        do {
            storedFiles = try storedFilesProvider()
            selectedStoredFileIDs.formIntersection(Set(storedFiles.map(\.id)))
        } catch {
            let detail = "저장 파일 목록을 다시 읽지 못했습니다. \(error.localizedDescription)"
            storedFileDeletionError = [storedFileDeletionError, detail].compactMap { $0 }.joined(separator: "\n")
        }
    }

    func exportSelectedFilesToUSB() async {
        guard !isExportingToUSB, !isReceivingFile,
              !isDeletingStoredFiles, !needsStoredFileDeletionConfirmation else { return }
        let selected = storedFiles.filter { selectedStoredFileIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isExportingToUSB = true
        usbExportProgress = nil
        lastUSBExportError = nil
        usbExportCompletionMessage = nil
        lastOriginalCleanupError = nil
        defer { isExportingToUSB = false }
        do {
            guard let destination = try bookmarkStore.resolve() else {
                throw USBReceiveServiceError.missingDestination
            }
            guard !destination.isStale else {
                throw USBReceiveServiceError.staleDestination
            }
            let summary = await exportFiles(selected, destination)
            selectedStoredFileIDs.subtract(summary.verified.map(\.sourceID))
            storedFiles = try storedFilesProvider()
            needsDeletionDecision = !pendingDeletionDecisions().isEmpty
            lastUSBExportError = summary.errorMessage
        } catch {
            lastUSBExportError = Self.message(for: error)
        }
    }

    func keepOriginals() async {
        let ids = Set(pendingDeletionDecisions().map(\.id))
        guard !ids.isEmpty else { return }
        lastOriginalCleanupError = nil
        do {
            try await keepOriginalFiles(ids)
            needsDeletionDecision = !pendingDeletionDecisions().isEmpty
            if !needsDeletionDecision, lastUSBExportError == nil {
                usbExportProgress = nil
                usbExportCompletionMessage = "USB 복사 완료 · iPhone 원본 \(ids.count)개 유지됨"
            }
        } catch {
            lastOriginalCleanupError = "원본 유지 결정을 저장하지 못했습니다. 원본은 삭제하지 않았습니다."
        }
    }

    func deleteOriginals() async {
        let ids = Set(pendingDeletionDecisions().map(\.id))
        guard !ids.isEmpty else { return }
        lastOriginalCleanupError = nil
        let summary = await deleteOriginalFiles(ids)
        needsDeletionDecision = !pendingDeletionDecisions().isEmpty
        do {
            storedFiles = try storedFilesProvider()
            selectedStoredFileIDs.formIntersection(Set(storedFiles.map(\.id)))
        } catch {
            lastOriginalCleanupError = "iPhone 저장 파일 목록을 다시 읽지 못했습니다."
            return
        }
        if !summary.failed.isEmpty {
            lastOriginalCleanupError = "iPhone 원본 \(summary.failed.count)개를 삭제하지 못했습니다. USB에 복사된 파일은 유지됩니다."
        } else if !needsDeletionDecision, lastUSBExportError == nil {
            usbExportProgress = nil
            usbExportCompletionMessage = "USB 복사 완료 · iPhone 원본 \(summary.deletedSourceIDs.count)개 삭제됨"
        }
    }

    var usbExportStageTitle: String {
        if lastUSBExportError != nil { return "USB 복사 실패" }
        if let usbExportCompletionMessage { return usbExportCompletionMessage }
        guard let progress = usbExportProgress else {
            return isExportingToUSB ? "USB 복사 준비 중" : "USB 복사 대기"
        }
        let position = progress.totalCount > 0
            ? " · \(progress.currentIndex)/\(progress.totalCount)"
            : ""
        switch progress.stage {
        case .copyingToUSB: return "USB로 복사 중\(position)"
        case .verifying: return "USB 복사 검증 중\(position)"
        case .completed: return "USB 복사 완료"
        case .failed: return "USB 복사 실패"
        default: return "USB 복사 준비 중\(position)"
        }
    }

    var usbExportByteText: String {
        guard let progress = usbExportProgress else { return "" }
        return "\(Self.byteText(progress.bytesReceived)) / \(Self.byteText(progress.totalBytes))"
    }

    var receiveStageTitle: String {
        guard let progress = receiveProgress else { return "PC 파일 수신 대기" }
        let position = progress.totalCount > 0
            ? " · \(progress.currentIndex)/\(progress.totalCount)"
            : ""
        let destination = progress.destination == .iphoneLocal ? "iPhone" : "USB"
        switch progress.stage {
        case .idle: return "PC 파일 수신 대기"
        case .discovering: return "새 파일 확인 중"
        case .waitingForDestination: return "저장 위치 선택 대기"
        case .downloading: return "\(destination) 저장 중\(position)"
        case .downloaded: return "다운로드 완료\(position)"
        case .verifying: return "파일·SHA 검증 중\(position)"
        case .finalizing: return "\(destination) 파일 확정 중\(position)"
        case .copyingToUSB: return "USB로 복사 중\(position)"
        case .acknowledging: return "PC에 저장 완료 알림 중\(position)"
        case .completed: return "\(destination) 저장 완료"
        case .paused: return "PC 파일 수신 일시정지"
        case .failed:
            return progress.deliveryID == nil ? "새 파일 확인 오류" : "\(destination) 수신 오류"
        }
    }

    var receivePercentText: String {
        guard let progress = receiveProgress, progress.totalBytes > 0,
              ![.idle, .discovering, .waitingForDestination, .completed, .failed]
                .contains(progress.stage) else { return "" }
        return "\(progress.percent)%"
    }

    var receiveByteText: String {
        guard let progress = receiveProgress, progress.totalBytes > 0 else { return "" }
        return "\(Self.byteText(progress.bytesReceived)) / \(Self.byteText(progress.totalBytes))"
    }

    var receiveSpeedText: String {
        guard receiveProgress?.stage == .downloading else { return "" }
        guard let progress = receiveProgress,
              let startedAt = progress.startedAt,
              progress.bytesReceived > 0 else { return "계산 중" }
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        return "\(Self.byteText(Int64(Double(progress.bytesReceived) / elapsed)))/초"
    }

    var receiveETAText: String {
        guard let progress = receiveProgress,
              progress.stage == .downloading,
              let startedAt = progress.startedAt,
              progress.bytesReceived > 0,
              progress.totalBytes > progress.bytesReceived else { return "" }
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let speed = Double(progress.bytesReceived) / elapsed
        let seconds = Int(Double(progress.totalBytes - progress.bytesReceived) / speed)
        return "약 \(max(seconds, 1))초 남음"
    }

    private func handleReceiveProgress(_ progress: USBReceiveProgress) {
        let previousStage = receiveProgress?.stage
        receiveProgress = progress
        if progress.stage == .failed {
            lastError = progress.errorMessage
        } else if previousStage == .failed || progress.stage != .idle {
            if !needsLocalFallbackDecision {
                lastError = nil
            }
        }

        if progress.stage == .completed || progress.stage == .failed {
            recordTerminalOutcome(progress)
        }

        if progress.stage == .completed, progress.destination == .iphoneLocal {
            do {
                storedFiles = try storedFilesProvider()
            } catch {
                lastError = "받은 파일 목록을 새로 고치지 못했습니다. " + Self.message(for: error)
            }
        }
    }

    private func recordTerminalOutcome(_ progress: USBReceiveProgress) {
        let activeReceiverID: UUID?
        if let receiverID {
            activeReceiverID = receiverID
        } else {
            activeReceiverID = try? registrationStore.load()?.identity.receiverID
            receiverID = activeReceiverID
        }
        guard let activeReceiverID else { return }

        let destination = progress.destination == .iphoneLocal ? "iPhone" : "USB"
        let kind: IPhoneReceiveOutcomeKind = progress.stage == .completed ? .saved : .failed
        let outcome = IPhoneReceiveOutcome(
            receiverID: activeReceiverID,
            kind: kind,
            destination: progress.destination,
            fileName: progress.fileName,
            totalCount: max(progress.totalCount, progress.completedCount),
            completedCount: progress.completedCount,
            message: kind == .saved
                ? "\(destination) 저장 완료"
                : (progress.errorMessage ?? "\(destination) 수신에 실패했습니다."),
            occurredAt: now()
        )
        receiveOutcome = outcome
        try? saveOutcome(outcome)
    }

    private func pollUSB() async throws {
        switch fallbackMode {
        case let .serverWait(waiting):
            let pending = try await pendingDeliveryIDs()
            if pending.isEmpty {
                resetFallback()
                return
            }
            if pending == waiting { return }
            resetFallback()
        case .none:
            break
        }

        do {
            _ = try await receiveOnce()
        } catch let error as USBReceiveServiceError where Self.isDestinationError(error) {
            let pending = try await pendingDeliveryIDs()
            guard !pending.isEmpty else { throw error }
            promptedDeliveryIDs = pending
            needsLocalFallbackDecision = true
            lastError = "USB를 사용할 수 없습니다. iPhone에 저장하거나 서버에 대기할 수 있습니다."
        }
    }

    private func resetFallback() {
        fallbackMode = .none
        promptedDeliveryIDs = []
        needsLocalFallbackDecision = false
    }

    private static func isDestinationError(_ error: USBReceiveServiceError) -> Bool {
        switch error {
        case .missingDestination, .staleDestination, .destinationChanged,
             .destinationNotWritable:
            return true
        default:
            return false
        }
    }

    private static func message(for error: Error) -> String {
        IPhoneReceiveErrorMessage.message(error)
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
        return String(
            format: "%.2fGB",
            Double(value) / Double(1_024 * 1_024 * 1_024)
        )
    }
}
