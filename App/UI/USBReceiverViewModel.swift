import Foundation

@MainActor
final class USBReceiverViewModel: ObservableObject {
    typealias ReceiveOnce = @Sendable () async throws -> USBReceiveSummary
    typealias ProgressUpdates = @Sendable () -> AsyncStream<USBReceiveProgress>
    typealias Sleep = @Sendable () async throws -> Void

    @Published private(set) var registrationCode: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var usbDisplayName: String?
    @Published private(set) var receiveProgress: USBReceiveProgress?
    @Published private(set) var isPolling = false
    @Published private(set) var lastError: String?
    @Published private(set) var allowsCellular: Bool

    private let uploadCredentialStore: CredentialStore
    private let registrationStore: IPhoneReceiverRegistrationStore
    private let bookmarkStore: USBBookmarkStore
    private let registrar: any IPhoneReceiverRegistering
    private let receiveOnce: ReceiveOnce
    private let defaultDeviceName: String
    private let sleep: Sleep
    private let preferences: USBReceiverPreferences
    private var progressTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    init(
        uploadCredentialStore: CredentialStore,
        registrationStore: IPhoneReceiverRegistrationStore,
        bookmarkStore: USBBookmarkStore,
        registrar: any IPhoneReceiverRegistering,
        receiveOnce: @escaping ReceiveOnce,
        progressUpdates: @escaping ProgressUpdates,
        defaultDeviceName: String,
        preferences: USBReceiverPreferences = USBReceiverPreferences(),
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds(2)) }
    ) {
        self.uploadCredentialStore = uploadCredentialStore
        self.registrationStore = registrationStore
        self.bookmarkStore = bookmarkStore
        self.registrar = registrar
        self.receiveOnce = receiveOnce
        self.defaultDeviceName = defaultDeviceName
        self.preferences = preferences
        allowsCellular = preferences.allowsCellular
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
    }

    deinit {
        progressTask?.cancel()
        pollingTask?.cancel()
    }

    var isRegistered: Bool { registrationCode != nil }
    var hasUSBDestination: Bool { usbDisplayName != nil }

    func refresh() async {
        do {
            let registration = try registrationStore.load()
            registrationCode = registration?.identity.code
            deviceName = registration?.identity.deviceName
            let destination = try bookmarkStore.resolve()
            usbDisplayName = destination?.displayName
            if destination?.isStale == true {
                lastError = "USB 폴더 권한이 만료되었습니다. 폴더를 다시 선택해 주세요."
            }
        } catch {
            lastError = "수신 설정을 읽지 못했습니다."
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
            lastError = nil
        } catch {
            lastError = "iPhone 수신 기기를 등록하지 못했습니다."
        }
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
                do {
                    _ = try await receiveOnce()
                    if receiveProgress?.stage != .failed { lastError = nil }
                } catch is CancellationError {
                    return
                } catch {
                    lastError = Self.message(for: error)
                }
                do {
                    try await sleep()
                } catch {
                    return
                }
            }
        }
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

    var receiveStageTitle: String {
        guard let progress = receiveProgress else { return "PC 파일 수신 대기" }
        let position = progress.totalCount > 0
            ? " · \(progress.currentIndex)/\(progress.totalCount)"
            : ""
        switch progress.stage {
        case .idle: return "PC 파일 수신 대기"
        case .discovering: return "새 파일 확인 중"
        case .downloading: return "USB 저장 중\(position)"
        case .verifying: return "파일·SHA 검증 중\(position)"
        case .finalizing: return "USB 파일 확정 중\(position)"
        case .acknowledging: return "PC에 저장 완료 알림 중\(position)"
        case .completed: return "USB 저장 완료"
        case .failed: return "USB 수신 오류"
        }
    }

    var receivePercentText: String {
        "\(receiveProgress?.percent ?? 0)%"
    }

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

    private static func message(for error: Error) -> String {
        switch error {
        case USBReceiveServiceError.missingRegistration:
            return "수신 기기를 먼저 등록해 주세요."
        case USBReceiveServiceError.missingDestination:
            return "USB 폴더를 먼저 선택해 주세요."
        case USBReceiveServiceError.staleDestination:
            return "USB 폴더 권한이 만료되었습니다. 다시 선택해 주세요."
        case USBReceiveServiceError.destinationChanged:
            return "선택한 USB와 현재 연결된 USB가 다릅니다."
        case USBReceiveServiceError.insufficientSpace:
            return "USB 저장 공간이 부족합니다."
        case USBReceiveServiceError.fat32FileTooLarge:
            return "FAT32 USB에는 4GiB 초과 파일을 저장할 수 없습니다. exFAT을 사용해 주세요."
        case USBReceiveServiceError.shaMismatch:
            return "파일 무결성 검증에 실패했습니다. 서버 파일을 다시 확인합니다."
        case let IPhoneReceiverClientError.server(statusCode, code):
            return "서버 오류 (HTTP \(statusCode) · \(code ?? "unknown"))"
        default:
            return "수신하지 못했습니다. 연결과 USB 상태를 확인해 주세요."
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
        return String(
            format: "%.2fGB",
            Double(value) / Double(1_024 * 1_024 * 1_024)
        )
    }
}
