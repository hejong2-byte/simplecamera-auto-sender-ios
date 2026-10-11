import Foundation
import Combine
import UserNotifications

enum TransferNotificationAuthorization: Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral
}

enum TransferNotificationOperation: String, Sendable {
    case receive, usbCopy
}

enum TransferNotificationOutcome: String, Sendable {
    case completed, failed, paused, cancelled
}

struct TransferNotificationEvent: Sendable, Equatable {
    let jobID: String
    let operation: TransferNotificationOperation
    let outcome: TransferNotificationOutcome
    let count: Int
}

struct TransferNotificationRequest: Sendable {
    let identifier: String
    let title: String
    let body: String
}

protocol TransferNotificationClient: Sendable {
    func authorizationStatus() async -> TransferNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func schedule(_ request: TransferNotificationRequest) async throws
}

@MainActor
final class TransferNotificationService: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isReady = false
    @Published private(set) var canOpenSettings = false
    @Published private(set) var readinessMessage = "알림 꺼짐"

    private let preferences: USBReceiverPreferences
    private let client: any TransferNotificationClient
    private var seen: [String: Set<TransferNotificationOutcome>] = [:]
    private var jobOrder: [String] = []
    private var isRequestingPermission = false

    init(preferences: USBReceiverPreferences, client: any TransferNotificationClient = SystemTransferNotificationClient()) {
        self.preferences = preferences
        self.client = client
        isEnabled = preferences.transferNotificationsEnabled
    }
    func setEnabled(_ enabled: Bool) async {
        preferences.transferNotificationsEnabled = enabled
        isEnabled = enabled
        if enabled {
            let status = await client.authorizationStatus()
            if preferences.transferNotificationsEnabled, status == .notDetermined, !isRequestingPermission {
                isRequestingPermission = true
                do { _ = try await client.requestAuthorization() }
                catch {
                    isRequestingPermission = false
                    await refreshAuthorization()
                    if preferences.transferNotificationsEnabled {
                        readinessMessage = "알림 권한 요청 실패 · 파일 작업에는 영향이 없습니다."
                    }
                    return
                }
                isRequestingPermission = false
            }
        }
        // Permission can finish after an opt-out. Never write the preference
        // again here; refresh from its current value after every OS await.
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        guard preferences.transferNotificationsEnabled else {
            isEnabled = false
            isReady = false
            canOpenSettings = false
            readinessMessage = "알림 꺼짐"
            return
        }
        let status = await client.authorizationStatus()
        guard preferences.transferNotificationsEnabled else {
            isEnabled = false
            isReady = false
            canOpenSettings = false
            readinessMessage = "알림 꺼짐"
            return
        }
        isEnabled = true
        isReady = [.authorized, .provisional, .ephemeral].contains(status)
        canOpenSettings = status == .denied
        readinessMessage = isReady ? "수신·USB 복사 결과 알림 켜짐" : (canOpenSettings ? "시스템 설정에서 알림이 차단됨" : "알림 권한 확인 필요")
    }

    func handle(_ event: TransferNotificationEvent) async {
        guard event.count > 0, event.outcome != .cancelled else { return }
        let job = event.operation.rawValue + ":" + event.jobID
        if seen[job] == nil {
            jobOrder.append(job)
            if jobOrder.count > 64 { seen.removeValue(forKey: jobOrder.removeFirst()) }
        }
        guard seen[job, default: []].insert(event.outcome).inserted else { return }
        // Mark even disabled/not-ready events as seen: enabling never replays history.
        guard preferences.transferNotificationsEnabled else { return }
        await refreshAuthorization()
        guard preferences.transferNotificationsEnabled, isReady else { return }
        let operation = event.operation == .receive ? "파일 수신" : "USB 복사"
        let outcome: String
        switch event.outcome {
        case .completed: outcome = "완료"
        case .failed: outcome = "실패"
        case .paused: outcome = "일시정지"
        case .cancelled: return
        }
        do {
            try await client.schedule(TransferNotificationRequest(identifier: job + ":" + event.outcome.rawValue,
                title: "\(operation) \(outcome)", body: "\(event.count)개 작업 · \(outcome). 앱에서 상태를 확인해 주세요."))
        } catch {
            guard preferences.transferNotificationsEnabled else { return }
            readinessMessage = "알림 예약 실패 · 파일 작업에는 영향이 없습니다."
        }
    }
}

struct SystemTransferNotificationClient: TransferNotificationClient {
    func authorizationStatus() async -> TransferNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        case .denied: return .denied
        default: return .notDetermined
        }
    }
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func schedule(_ request: TransferNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.identifier,
            content: content, trigger: nil))
    }
}
