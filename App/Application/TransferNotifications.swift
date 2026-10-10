import Foundation
import Combine

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
    @Published private(set) var isReady = false
    @Published private(set) var canOpenSettings = false
    @Published private(set) var readinessMessage = "알림 꺼짐"

    init(preferences: USBReceiverPreferences, client: any TransferNotificationClient) {}
    func setEnabled(_ enabled: Bool) async {}
    func refreshAuthorization() async {}
    func handle(_ event: TransferNotificationEvent) async {}
}
