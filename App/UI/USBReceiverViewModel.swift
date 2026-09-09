import Foundation
import QuickLook

enum IPhoneReceiveStatusKind: Sendable, Equatable {
    case warning
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
    typealias DeleteStoredFiles = @Sendable ([IPhoneStoredFile], @Sendable (FileDeletionProgress) -> Void) async throws -> IPhoneStoredFileDeletionSummary
    typealias ExportFiles = @Sendable (
        [IPhoneStoredFile],
        USBBookmarkDestination,
        IPhoneReceiveArchiveMode
    ) async -> IPhoneUSBExportSummary
    typealias PendingDeletionDecisions = @Sendable () -> [IPhoneUSBDeletionDecision]
    typealias VerifyCopies = @Sendable ([IPhoneStoredFile], USBBookmarkDestination, @Sendable (USBReceiveProgress) -> Void) async -> IPhoneUSBExportSummary
    typealias KeepOriginals = @Sendable (Set<UUID>) async throws -> Void
    typealias DeleteOriginals = @Sendable (Set<UUID>) async -> IPhoneUSBDeletionSummary
    typealias InspectUSBFolder = @Sendable (
        USBBookmarkDestination
    ) async throws -> USBFolderContentsSummary
    typealias DeleteUSBFolderContents = @Sendable (
        USBBookmarkDestination,
        USBFolderContentsSummary,
        @Sendable (FileDeletionProgress) -> Void
    ) async throws -> USBFolderDeletionSummary
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
    @Published private(set) var usbFileSystemDescription: String?
    @Published private(set) var isUSBAvailable: Bool?
    @Published private(set) var receiveProgress: USBReceiveProgress?
    @Published private(set) var receiveOutcome: IPhoneReceiveOutcome?
    @Published private(set) var receiveOutcomeDismissalError: String?
    @Published private(set) var usbExportProgress: USBReceiveProgress?
    @Published private(set) var usbExportLastUpdatedAt: Date?
    @Published private(set) var lastUSBExportError: String?
    @Published private(set) var usbExportCompletionMessage: String?
    @Published private(set) var lastOriginalCleanupError: String?
    @Published private(set) var isExportingToUSB = false
    @Published private(set) var isCancellingUSBCopy = false
    @Published private(set) var isVerifyingUSBCopies = false
    @Published private(set) var usbVerificationMessage: String?
    @Published private(set) var usbVerificationFailed = false
    @Published private(set) var usbVerificationProgress: USBReceiveProgress?
    @Published private(set) var isPolling = false
    @Published private(set) var lastError: String?
    @Published private(set) var allowsCellular: Bool
    @Published private(set) var selectedDestination: IPhoneReceiveDestination
    @Published private(set) var storedFiles: [IPhoneStoredFile] = []
    @Published private(set) var selectedStoredFileIDs: Set<String> = []
    @Published private(set) var storedFilesPendingDeletion: [IPhoneStoredFile] = []
    @Published private(set) var storedZIPExportFilesPendingChoice: [IPhoneStoredFile] = []
    @Published private(set) var isDeletingStoredFiles = false
    @Published private(set) var storedFileDeletionProgress: FileDeletionProgress?
    @Published private(set) var usbFolderDeletionProgress: FileDeletionProgress?
    @Published private(set) var storedFileDeletionMessage: String?
    @Published private(set) var storedFileDeletionError: String?
    @Published var previewFile: IPhoneStoredFile?
    @Published var storedFilePreviewError: String?
    @Published private(set) var needsLocalFallbackDecision = false
    @Published private(set) var needsDeletionDecision = false
    @Published var isChoosingUSBFolder = false
    @Published var isShowingSettingsConfirmation = false
    @Published private(set) var isPerformingReceive = false
    @Published private(set) var isInspectingUSBFolderContents = false
    @Published private(set) var isDeletingUSBFolderContents = false
    @Published private(set) var usbFolderContentsPendingDeletion: USBFolderContentsSummary?
    @Published private(set) var usbFolderDeletionMessage: String?
    @Published private(set) var usbFolderDeletionError: String?

    private enum USBFallbackMode {
        case none
        case serverWait(Set<UUID>)
    }

    private let uploadCredentialStore: CredentialStore
    private let registrationStore: IPhoneReceiverRegistrationStore
    private let bookmarkStore: USBBookmarkStore
    private let checkUSBAvailability: @Sendable (USBBookmarkDestination) -> Bool
    private var cachedUSBDestination: USBBookmarkDestination?
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
    private let verifyCopies: VerifyCopies
    private let pendingDeletionDecisions: PendingDeletionDecisions
    private let keepOriginalFiles: KeepOriginals
    private let deleteOriginalFiles: DeleteOriginals
    private let inspectUSBFolder: InspectUSBFolder
    private let deleteUSBFolderContents: DeleteUSBFolderContents
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
    private var usbDestinationPendingDeletion: USBBookmarkDestination?

    init(
        uploadCredentialStore: CredentialStore,
        registrationStore: IPhoneReceiverRegistrationStore,
        bookmarkStore: USBBookmarkStore,
        checkUSBAvailability: @escaping @Sendable (USBBookmarkDestination) -> Bool = { USBFolderAvailability.check($0) },
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
        deleteStoredFiles: @escaping DeleteStoredFiles = { _, _ in
            throw CocoaError(.featureUnsupported)
        },
        exportFiles: @escaping ExportFiles = { _, _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        },
        pendingDeletionDecisions: @escaping PendingDeletionDecisions = { [] },
        verifyCopies: @escaping VerifyCopies = { files, _, _ in
            IPhoneUSBExportSummary(verified: [], failed: files.map {
                IPhoneUSBExportFailure(sourceID: $0.id, error: .verificationRecordMissing)
            })
        },
        keepOriginals: @escaping KeepOriginals = { _ in },
        deleteOriginals: @escaping DeleteOriginals = { _ in
            IPhoneUSBDeletionSummary(deletedSourceIDs: [], failed: [])
        },
        inspectUSBFolder: @escaping InspectUSBFolder = { _ in
            throw CocoaError(.featureUnsupported)
        },
        deleteUSBFolderContents: @escaping DeleteUSBFolderContents = { _, _, _ in
            throw CocoaError(.featureUnsupported)
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
        self.checkUSBAvailability = checkUSBAvailability
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
        self.verifyCopies = verifyCopies
        self.pendingDeletionDecisions = pendingDeletionDecisions
        self.keepOriginalFiles = keepOriginals
        self.deleteOriginalFiles = deleteOriginals
        self.inspectUSBFolder = inspectUSBFolder
        self.deleteUSBFolderContents = deleteUSBFolderContents
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
                self?.usbExportLastUpdatedAt = Date()
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

    var usbConnectionMessage: String? {
        guard hasUSBDestination else { return nil }
        guard let isUSBAvailable else { return "USB 연결 확인 중" }
        return isUSBAvailable ? "USB 연결 확인됨"
            : "USB 연결이 끊겼거나 폴더에 접근할 수 없습니다. 다시 연결하거나 폴더를 선택해 주세요."
    }

    func monitorUSBAvailability() async {
        if cachedUSBDestination == nil {
            do {
                let destination = try await Task.detached { [bookmarkStore] in
                    try bookmarkStore.resolve()
                }.value
                guard !Task.isCancelled else { return }
                cachedUSBDestination = destination
                usbDisplayName = destination?.displayName
                usbFileSystemDescription = destination?.formatDescription
            } catch { isUSBAvailable = false }
        }
        while !Task.isCancelled {
            if let destination = cachedUSBDestination {
                let available = await Task.detached { [checkUSBAvailability] in
                    checkUSBAvailability(destination)
                }.value
                guard !Task.isCancelled else { return }
                if cachedUSBDestination == destination, isUSBAvailable != available {
                    isUSBAvailable = available
                }
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    var hasStoredFileSelection: Bool { !selectedStoredFileIDs.isEmpty }
    var needsStoredFileDeletionConfirmation: Bool { !storedFilesPendingDeletion.isEmpty }
    var needsStoredZIPExportChoice: Bool { !storedZIPExportFilesPendingChoice.isEmpty }
    var needsUSBFolderDeletionConfirmation: Bool {
        usbFolderContentsPendingDeletion != nil
    }
    var isCleaningUSBFolder: Bool {
        isInspectingUSBFolderContents
            || isDeletingUSBFolderContents
            || needsUSBFolderDeletionConfirmation
    }
    var canDeleteStoredFiles: Bool {
        hasStoredFileSelection && !isDeletingStoredFiles
    }
    var pendingDeletionCount: Int { pendingDeletionDecisions().count }
    var isReceivingFile: Bool {
        guard let stage = receiveProgress?.stage else { return false }
        return (isPerformingReceive || receiveProgress?.destination == .iphoneLocal)
            && [
                .discovering, .waitingForDestination, .downloading, .downloaded,
                .extracting, .verifying, .finalizing, .copyingToUSB, .acknowledging
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
            case .receiptPending, .savedWithoutReceipt:
                return IPhoneReceiveStatus(
                    kind: .warning,
                    title: outcome.kind == .receiptPending ? "iPhone 저장 완료 · 서버 확인 대기" : "iPhone 저장 완료 · 서버 확인 불가",
                    message: outcome.message, fileName: outcome.fileName,
                    occurredAt: outcome.occurredAt, percent: nil
                )
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

    var canDismissReceiveOutcome: Bool {
        receiveOutcome != nil && !isReceivingFile && !isPerformingReceive
    }

    func dismissReceiveOutcome() {
        guard canDismissReceiveOutcome, let outcome = receiveOutcome,
              outcome.receiverID == receiverID else { return }
        do {
            try clearOutcome(outcome.receiverID)
            receiveOutcome = nil
            receiveOutcomeDismissalError = nil
            if lastError == outcome.message { lastError = nil }
        } catch {
            receiveOutcomeDismissalError = "알림을 닫지 못했습니다. 다시 시도해 주세요."
        }
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
            // Resolving a disconnected external volume can wait on its file provider.
            // Keep the main actor available for the incoming-file picker and navigation.
            let destination = try await Task.detached(priority: .userInitiated) { [bookmarkStore] in
                try bookmarkStore.resolve()
            }.value
            usbDisplayName = destination?.displayName
            usbFileSystemDescription = destination?.formatDescription
            cachedUSBDestination = destination
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
            usbFileSystemDescription = destination?.formatDescription
            cachedUSBDestination = destination
            isUSBAvailable = nil
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
            usbFileSystemDescription = nil
            cachedUSBDestination = nil
            isUSBAvailable = nil
            cancelUSBFolderDeletion()
            usbFolderDeletionMessage = nil
            usbFolderDeletionError = nil
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
              !isDeletingStoredFiles, !needsStoredFileDeletionConfirmation,
              !isCleaningUSBFolder else { return }
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
                clearRecoveredDiscoveryOutcome()
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
        guard !isDeletingStoredFiles, !needsStoredFileDeletionConfirmation,
              !needsStoredZIPExportChoice else { return }
        if selectedStoredFileIDs.contains(id) {
            selectedStoredFileIDs.remove(id)
        } else {
            selectedStoredFileIDs.insert(id)
        }
    }

    func requestStoredFileDeletion() {
        guard canDeleteStoredFiles, !needsStoredFileDeletionConfirmation,
              !isChoosingUSBFolder, !needsDeletionDecision,
              !needsLocalFallbackDecision, !isCleaningUSBFolder,
              !needsStoredZIPExportChoice else { return }
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
        guard !storedFilesPendingDeletion.isEmpty, !isDeletingStoredFiles,
              !isCleaningUSBFolder else { return }
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
        storedFileDeletionProgress = FileDeletionProgress(totalCount: confirmedFiles.count, processedCount: 0, failedCount: 0, currentName: nil)
        let (updates, continuation) = AsyncStream<FileDeletionProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task { for await value in updates { storedFileDeletionProgress = value } }
        do {
            let summary = try await deleteStoredFiles(confirmedFiles) { continuation.yield($0) }
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
        continuation.finish()
        await progressTask.value
        do {
            storedFiles = try storedFilesProvider()
            selectedStoredFileIDs.formIntersection(Set(storedFiles.map(\.id)))
        } catch {
            let detail = "저장 파일 목록을 다시 읽지 못했습니다. \(error.localizedDescription)"
            storedFileDeletionError = [storedFileDeletionError, detail].compactMap { $0 }.joined(separator: "\n")
        }
    }

    func exportSelectedFilesToUSB() async {
        await requestStoredFilesUSBExport()
    }

    func requestStoredFilesUSBExport() async {
        guard !isExportingToUSB, !isReceivingFile,
              !isDeletingStoredFiles, !needsStoredFileDeletionConfirmation,
              !isCleaningUSBFolder, !needsStoredZIPExportChoice else { return }
        let selected = storedFiles.filter { selectedStoredFileIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        if selected.contains(where: Self.isZIP) {
            storedZIPExportFilesPendingChoice = selected
            return
        }
        await exportStoredFiles(selected, archiveMode: .keepArchive)
    }

    func cancelStoredZIPExportChoice() {
        storedZIPExportFilesPendingChoice = []
    }

    func confirmStoredZIPExport(_ archiveMode: IPhoneReceiveArchiveMode) async {
        let selected = storedZIPExportFilesPendingChoice
        guard !selected.isEmpty else { return }
        storedZIPExportFilesPendingChoice = []
        await exportStoredFiles(selected, archiveMode: archiveMode)
    }

    var canCancelUSBCopy: Bool { false }

    func cancelUSBCopy() {}

    private func exportStoredFiles(
        _ selected: [IPhoneStoredFile],
        archiveMode: IPhoneReceiveArchiveMode
    ) async {
        guard !isExportingToUSB, !isReceivingFile,
              !isDeletingStoredFiles, !needsStoredFileDeletionConfirmation,
              !isCleaningUSBFolder else { return }
        isExportingToUSB = true
        usbExportProgress = nil
        lastUSBExportError = nil
        usbExportCompletionMessage = nil
        usbVerificationMessage = nil
        lastOriginalCleanupError = nil
        defer { isExportingToUSB = false }
        do {
            guard let destination = try await Task.detached(priority: .userInitiated, operation: { [bookmarkStore] in
                try bookmarkStore.resolve()
            }).value else {
                throw USBReceiveServiceError.missingDestination
            }
            guard !destination.isStale else {
                throw USBReceiveServiceError.staleDestination
            }
            let summary = await exportFiles(selected, destination, archiveMode)
            selectedStoredFileIDs.subtract(summary.verified.map(\.sourceID))
            storedFiles = try storedFilesProvider()
            needsDeletionDecision = !pendingDeletionDecisions().isEmpty
            lastUSBExportError = summary.errorMessage
        } catch {
            lastUSBExportError = Self.message(for: error)
        }
    }

    private static func isZIP(_ file: IPhoneStoredFile) -> Bool {
        file.url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame
    }

    func verifySelectedUSBCopies() async {
        guard !isExportingToUSB, !isReceivingFile, !isPerformingReceive,
              !isDeletingStoredFiles, !needsStoredFileDeletionConfirmation,
              !isCleaningUSBFolder, !isChoosingUSBFolder, !needsDeletionDecision,
              !needsStoredZIPExportChoice else { return }
        let selected = storedFiles.filter { selectedStoredFileIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isExportingToUSB = true
        isVerifyingUSBCopies = true
        usbVerificationProgress = nil
        usbVerificationMessage = nil
        usbVerificationFailed = false
        defer {
            isExportingToUSB = false
            isVerifyingUSBCopies = false
        }
        do {
            guard let destination = try await Task.detached(priority: .userInitiated, operation: { [bookmarkStore] in
                try bookmarkStore.resolve()
            }).value else {
                throw USBReceiveServiceError.missingDestination
            }
            let (updates, continuation) = AsyncStream<USBReceiveProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let collector = Task { @MainActor in
                for await value in updates {
                    self.usbVerificationProgress = value
                    self.usbExportLastUpdatedAt = Date()
                }
            }
            let result = await verifyCopies(selected, destination) { continuation.yield($0) }
            continuation.finish()
            await collector.value
            usbVerificationFailed = !result.failed.isEmpty
            usbVerificationMessage = result.failed.isEmpty
                ? "정밀 SHA 검증 완료 · \(result.verified.count)개"
                : "정밀 SHA 검증 실패 · \(result.failed.count)개\n\(result.failed.first?.message ?? "")"
        } catch {
            usbVerificationFailed = true
            usbVerificationMessage = "정밀 검증을 시작하지 못했습니다. \(Self.message(for: error))"
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

    func prepareUSBFolderDeletion() async {
        guard !isCleaningUSBFolder, !isChoosingUSBFolder,
              !isPerformingReceive, !isReceivingFile,
              !isExportingToUSB, !isDeletingStoredFiles,
              !needsStoredFileDeletionConfirmation,
              !needsDeletionDecision, !needsLocalFallbackDecision else { return }
        isInspectingUSBFolderContents = true
        usbFolderDeletionMessage = nil
        usbFolderDeletionError = nil
        defer { isInspectingUSBFolderContents = false }
        do {
            guard let destination = try bookmarkStore.resolve() else {
                throw USBReceiveServiceError.missingDestination
            }
            let summary = try await inspectUSBFolder(destination)
            usbFileSystemDescription = summary.fileSystemDescription
                ?? destination.formatDescription
            guard summary.totalItemCount > 0 else {
                usbFolderDeletionMessage = "선택한 SD/USB 폴더가 이미 비어 있습니다."
                return
            }
            usbDestinationPendingDeletion = destination
            usbFolderContentsPendingDeletion = summary
        } catch {
            usbFolderDeletionError = Self.message(for: error)
        }
    }

    func cancelUSBFolderDeletion() {
        usbDestinationPendingDeletion = nil
        usbFolderContentsPendingDeletion = nil
    }

    func deleteConfirmedUSBFolderContents() async {
        guard !isDeletingUSBFolderContents,
              let confirmedDestination = usbDestinationPendingDeletion,
              let confirmedSummary = usbFolderContentsPendingDeletion else { return }
        cancelUSBFolderDeletion()
        guard !isPerformingReceive, !isReceivingFile,
              !isExportingToUSB, !isDeletingStoredFiles else {
            usbFolderDeletionError = "전송 중에는 SD/USB 파일을 삭제할 수 없습니다."
            return
        }
        isDeletingUSBFolderContents = true
        usbFolderDeletionMessage = nil
        usbFolderDeletionError = nil
        defer { isDeletingUSBFolderContents = false }
        usbFolderDeletionProgress = nil
        let (updates, continuation) = AsyncStream<FileDeletionProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task { for await value in updates { usbFolderDeletionProgress = value } }
        do {
            guard let currentDestination = try bookmarkStore.resolve() else {
                throw USBReceiveServiceError.missingDestination
            }
            guard currentDestination.volumeID == confirmedDestination.volumeID,
                  currentDestination.url.standardizedFileURL.path
                    == confirmedDestination.url.standardizedFileURL.path else {
                throw USBFolderCleanupError.destinationChanged
            }
            let result = try await deleteUSBFolderContents(
                currentDestination,
                confirmedSummary,
                { continuation.yield($0) }
            )
            if result.failures.isEmpty, result.remainingItemCount == 0 {
                usbFolderDeletionMessage = "SD/USB 파일 \(result.deletedItemCount)개 삭제 완료"
            } else {
                let firstFailure = result.failures.first?.message
                    ?? "삭제되지 않은 항목이 \(result.remainingItemCount)개 있습니다."
                usbFolderDeletionError = "일부 파일을 삭제하지 못했습니다. \(firstFailure)"
            }
        } catch {
            usbFolderDeletionError = Self.message(for: error)
        }
        continuation.finish()
        await progressTask.value
    }

    var usbFolderDeletionConfirmationTitle: String {
        guard let summary = usbFolderContentsPendingDeletion else {
            return "SD/USB 전체 파일 삭제"
        }
        return "‘\(summary.folderName)’의 모든 파일을 삭제할까요?"
    }

    var usbFolderDeletionConfirmationMessage: String {
        guard let summary = usbFolderContentsPendingDeletion else { return "" }
        return "파일 \(summary.fileCount)개 · 폴더 \(summary.directoryCount)개 · \(Self.byteText(summary.totalBytes))\n\n선택한 폴더 자체는 유지되며, iPhone에 저장된 파일은 삭제하지 않습니다. 이 작업은 되돌릴 수 없습니다."
    }

    var usbExportStageTitle: String {
        if isVerifyingUSBCopies { return "선택한 USB 복사본 정밀 SHA 검증 중" }
        if lastUSBExportError != nil { return "USB 복사 실패" }
        if let usbExportCompletionMessage { return usbExportCompletionMessage }
        guard let progress = usbExportProgress else {
            return isExportingToUSB ? "USB 복사 준비 중" : "USB 복사 대기"
        }
        let position = progress.totalCount > 0
            ? " · \(progress.currentIndex)/\(progress.totalCount)"
            : ""
        switch progress.stage {
        case .checkingSource: return "ZIP 원본 검사 중\(position)"
        case .extracting: return "ZIP 압축 해제 중\(position)"
        case .copyingToUSB: return "USB로 복사 중\(position)"
        case .verifying: return "USB 복사 검증 중\(position)"
        case .finalizing: return "복사 결과 정리 중\(position)"
        case .completed: return "USB 복사 완료"
        case .failed: return "USB 복사 실패"
        default: return "USB 복사 준비 중\(position)"
        }
    }

    var usbExportByteText: String {
        guard let progress = visibleUSBExportProgress else { return "" }
        return "\(Self.byteText(progress.bytesReceived)) / \(Self.byteText(progress.totalBytes))"
    }

    var visibleUSBExportProgress: USBReceiveProgress? {
        isVerifyingUSBCopies ? usbVerificationProgress : usbExportProgress
    }

    var usbExportDisplayedPercent: Int {
        guard let progress = visibleUSBExportProgress else { return 0 }
        if progress.stage == .copyingToUSB || progress.stage == .finalizing {
            return min(99, progress.percent)
        }
        return progress.percent
    }

    func usbExportSpeedText(at date: Date) -> String? {
        guard let progress = visibleUSBExportProgress,
              progress.stage == .copyingToUSB || progress.stage == .verifying,
              let start = progress.startedAt,
              date.timeIntervalSince(start) >= 1 else { return nil }
        let rate = Double(progress.bytesReceived) / date.timeIntervalSince(start) / 1_000_000
        return String(format: "현재 단계 평균 %.1f MB/s", locale: Locale(identifier: "en_US_POSIX"), rate)
    }

    func usbExportRemainingTimeText(at date: Date) -> String? {
        guard let progress = visibleUSBExportProgress, progress.stage == .copyingToUSB else { return nil }
        if progress.totalBytes > 0, progress.bytesReceived >= progress.totalBytes {
            return "파일 기록 마무리 중"
        }
        if let updatedAt = usbExportLastUpdatedAt, date.timeIntervalSince(updatedAt) >= 5 {
            return "진행 응답 대기 · 남은 시간 다시 계산 중"
        }
        guard let start = progress.startedAt, date.timeIntervalSince(start) >= 2,
              progress.bytesReceived > 0, progress.totalBytes > progress.bytesReceived else {
            return "남은 시간 계산 중"
        }
        let estimate = Double(progress.totalBytes - progress.bytesReceived)
            * date.timeIntervalSince(start) / Double(progress.bytesReceived)
        guard estimate.isFinite, estimate < Double(Int.max) else { return "남은 시간 계산 중" }
        let seconds = max(1, Int(ceil(estimate)))
        let duration: String
        if seconds >= 3_600 {
            duration = "\(seconds / 3_600)시간 \((seconds % 3_600) / 60)분"
        } else if seconds >= 60 {
            duration = "\(Int(ceil(Double(seconds) / 60)))분"
        } else {
            duration = "\(seconds)초"
        }
        return "현재 복사 작업 · 약 \(duration) 남음"
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
        case .extracting: return "ZIP 압축 해제 중\(position)"
        case .verifying: return "파일·SHA 검증 중\(position)"
        case .finalizing: return "\(destination) 파일 확정 중\(position)"
        case .copyingToUSB: return "USB로 복사 중\(position)"
        case .acknowledging: return "PC에 저장 완료 알림 중\(position)"
        case .receiptPending: return "iPhone 저장 완료 · 서버 확인 대기"
        case .savedWithoutReceipt: return "iPhone 저장 완료 · 서버 확인 불가"
        case .checkingSource: return "ZIP 원본 검사 중\(position)"
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
        if progress.stage == .idle, previousStage != nil {
            clearRecoveredDiscoveryOutcome()
        }

        if [.completed, .failed, .receiptPending, .savedWithoutReceipt].contains(progress.stage) {
            recordTerminalOutcome(progress)
        }

        if [.completed, .receiptPending, .savedWithoutReceipt].contains(progress.stage), progress.destination == .iphoneLocal {
            do {
                storedFiles = try storedFilesProvider()
            } catch {
                lastError = "받은 파일 목록을 새로 고치지 못했습니다. " + Self.message(for: error)
            }
        }
    }

    private func clearRecoveredDiscoveryOutcome() {
        guard receiveOutcome?.kind == .failed,
              receiveOutcome?.fileName == nil,
              let receiverID else { return }
        do {
            try clearOutcome(receiverID)
            receiveOutcome = nil
        } catch {
            lastError = "복구된 새 파일 확인 오류 기록을 정리하지 못했습니다."
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
        let kind: IPhoneReceiveOutcomeKind
        switch progress.stage {
        case .completed: kind = .saved
        case .receiptPending: kind = .receiptPending
        case .savedWithoutReceipt: kind = .savedWithoutReceipt
        default: kind = .failed
        }
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
        receiveOutcomeDismissalError = nil
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
