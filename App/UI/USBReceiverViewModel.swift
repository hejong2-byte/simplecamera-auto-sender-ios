import Foundation

@MainActor
final class USBReceiverViewModel: ObservableObject {
    typealias ReceiveOnce = @Sendable () async throws -> USBReceiveSummary
    typealias ReceiveLocalOnce = @Sendable () async throws -> Void
    typealias PendingDeliveryIDs = @Sendable () async throws -> Set<UUID>
    typealias StoredFilesProvider = @Sendable () throws -> [IPhoneStoredFile]
    typealias ExportFiles = @Sendable (
        [IPhoneStoredFile],
        USBBookmarkDestination
    ) async -> IPhoneUSBExportSummary
    typealias PendingDeletionDecisions = @Sendable () -> [IPhoneUSBDeletionDecision]
    typealias KeepOriginals = @Sendable (Set<UUID>) async throws -> Void
    typealias DeleteOriginals = @Sendable (Set<UUID>) async -> IPhoneUSBDeletionSummary
    typealias RefreshFeatures = @Sendable () async throws -> Void
    typealias ProgressUpdates = @Sendable () -> AsyncStream<USBReceiveProgress>
    typealias Sleep = @Sendable () async throws -> Void

    @Published private(set) var registrationCode: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var usbDisplayName: String?
    @Published private(set) var receiveProgress: USBReceiveProgress?
    @Published private(set) var usbExportProgress: USBReceiveProgress?
    @Published private(set) var lastUSBExportError: String?
    @Published private(set) var isExportingToUSB = false
    @Published private(set) var isPolling = false
    @Published private(set) var lastError: String?
    @Published private(set) var allowsCellular: Bool
    @Published private(set) var selectedDestination: IPhoneReceiveDestination
    @Published private(set) var storedFiles: [IPhoneStoredFile] = []
    @Published private(set) var selectedStoredFileIDs: Set<String> = []
    @Published private(set) var needsLocalFallbackDecision = false
    @Published private(set) var needsDeletionDecision = false

    private enum USBFallbackMode {
        case none
        case local(Set<UUID>)
        case serverWait(Set<UUID>)
    }

    private let uploadCredentialStore: CredentialStore
    private let registrationStore: IPhoneReceiverRegistrationStore
    private let bookmarkStore: USBBookmarkStore
    private let registrar: any IPhoneReceiverRegistering
    private let receiveOnce: ReceiveOnce
    private let receiveLocalOnce: ReceiveLocalOnce
    private let pendingDeliveryIDs: PendingDeliveryIDs
    private let storedFilesProvider: StoredFilesProvider
    private let exportFiles: ExportFiles
    private let pendingDeletionDecisions: PendingDeletionDecisions
    private let keepOriginalFiles: KeepOriginals
    private let deleteOriginalFiles: DeleteOriginals
    private let refreshFeatures: RefreshFeatures
    private let defaultDeviceName: String
    private let sleep: Sleep
    private let preferences: USBReceiverPreferences
    private var progressTask: Task<Void, Never>?
    private var exportProgressTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var fallbackMode: USBFallbackMode = .none
    private var promptedDeliveryIDs: Set<UUID> = []

    init(
        uploadCredentialStore: CredentialStore,
        registrationStore: IPhoneReceiverRegistrationStore,
        bookmarkStore: USBBookmarkStore,
        registrar: any IPhoneReceiverRegistering,
        receiveOnce: @escaping ReceiveOnce,
        receiveLocalOnce: @escaping ReceiveLocalOnce = {},
        pendingDeliveryIDs: @escaping PendingDeliveryIDs = { [] },
        storedFiles: @escaping StoredFilesProvider = { [] },
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
        self.storedFilesProvider = storedFiles
        self.exportFiles = exportFiles
        self.pendingDeletionDecisions = pendingDeletionDecisions
        self.keepOriginalFiles = keepOriginals
        self.deleteOriginalFiles = deleteOriginals
        self.refreshFeatures = refreshFeatures
        self.defaultDeviceName = defaultDeviceName
        self.preferences = preferences
        allowsCellular = preferences.allowsCellular
        selectedDestination = preferences.selectedDestination
        self.sleep = sleep
        progressTask = Task { [weak self] in
            for await progress in progressUpdates() {
                guard !Task.isCancelled else { break }
                self?.receiveProgress = progress
                if progress.stage == .failed {
                    self?.lastError = progress.errorMessage
                }
            }
        }
        exportProgressTask = Task { [weak self] in
            for await progress in exportProgressUpdates() {
                guard !Task.isCancelled else { break }
                guard progress.stage != .idle else { continue }
                self?.usbExportProgress = progress
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
    var pendingDeletionCount: Int { pendingDeletionDecisions().count }

    func refresh() async {
        do {
            let registration = try registrationStore.load()
            registrationCode = registration?.identity.code
            deviceName = registration?.identity.deviceName
            if registration != nil { try await refreshFeatures() }
            let destination = try bookmarkStore.resolve()
            usbDisplayName = destination?.displayName
            storedFiles = try storedFilesProvider()
            selectedStoredFileIDs.formIntersection(Set(storedFiles.map(\.id)))
            needsDeletionDecision = !pendingDeletionDecisions().isEmpty
            if selectedDestination == .usb, destination?.isStale == true {
                lastError = "USB 폴더 권한이 만료되었습니다. 폴더를 다시 선택해 주세요."
            }
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
            registrationCode = registration.code
            deviceName = registration.deviceName
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
            try registrationStore.clear()
            registrationCode = nil
            deviceName = nil
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
        guard !isExportingToUSB else { return }
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
        } catch is CancellationError {
            return
        } catch {
            lastError = Self.message(for: error)
        }
    }

    func chooseLocalFallback() async {
        guard !promptedDeliveryIDs.isEmpty else { return }
        fallbackMode = .local(promptedDeliveryIDs)
        needsLocalFallbackDecision = false
        lastError = nil
        do { try await receiveLocalOnce() } catch { lastError = Self.message(for: error) }
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
        if selectedStoredFileIDs.contains(id) {
            selectedStoredFileIDs.remove(id)
        } else {
            selectedStoredFileIDs.insert(id)
        }
    }

    func exportSelectedFilesToUSB() async {
        guard !isExportingToUSB else { return }
        let selected = storedFiles.filter { selectedStoredFileIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isExportingToUSB = true
        usbExportProgress = nil
        lastUSBExportError = nil
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
        do {
            try await keepOriginalFiles(ids)
            needsDeletionDecision = !pendingDeletionDecisions().isEmpty
        } catch {
            lastUSBExportError = "원본 유지 결정을 저장하지 못했습니다."
        }
    }

    func deleteOriginals() async {
        let ids = Set(pendingDeletionDecisions().map(\.id))
        let summary = await deleteOriginalFiles(ids)
        do { storedFiles = try storedFilesProvider() } catch {
            lastUSBExportError = "iPhone 저장 파일 목록을 다시 읽지 못했습니다."
        }
        needsDeletionDecision = !pendingDeletionDecisions().isEmpty
        if !summary.failed.isEmpty {
            lastUSBExportError = "변경되었거나 찾을 수 없는 원본 \(summary.failed.count)개는 삭제하지 않았습니다."
        }
    }

    var usbExportStageTitle: String {
        if lastUSBExportError != nil { return "USB 복사 실패" }
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
        case .failed: return "\(destination) 수신 오류"
        }
    }

    var receivePercentText: String { "\(receiveProgress?.percent ?? 0)%" }

    var receiveByteText: String {
        guard let progress = receiveProgress else { return "" }
        return "\(Self.byteText(progress.bytesReceived)) / \(Self.byteText(progress.totalBytes))"
    }

    var receiveSpeedText: String {
        guard let progress = receiveProgress,
              let startedAt = progress.startedAt,
              progress.bytesReceived > 0 else { return "계산 중" }
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        return "\(Self.byteText(Int64(Double(progress.bytesReceived) / elapsed)))/초"
    }

    var receiveETAText: String {
        guard let progress = receiveProgress,
              let startedAt = progress.startedAt,
              progress.bytesReceived > 0,
              progress.totalBytes > progress.bytesReceived else { return "" }
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let speed = Double(progress.bytesReceived) / elapsed
        let seconds = Int(Double(progress.totalBytes - progress.bytesReceived) / speed)
        return "약 \(max(seconds, 1))초 남음"
    }

    private func pollUSB() async throws {
        switch fallbackMode {
        case .local:
            let pending = try await pendingDeliveryIDs()
            if pending.isEmpty { resetFallback() } else { try await receiveLocalOnce() }
            return
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
