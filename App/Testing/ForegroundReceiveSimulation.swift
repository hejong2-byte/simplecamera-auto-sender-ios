#if DEBUG && targetEnvironment(simulator)
import Foundation

// UI tests use synthetic metadata and a temporary directory; never the relay or Keychain.
@MainActor
final class ForegroundReceiveSimulation {
    static let current: ForegroundReceiveSimulation? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test-incoming") else { return nil }
        let index = arguments.firstIndex(of: "--ui-test-incoming-delay")
        let delay = index.flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 0
        return try! ForegroundReceiveSimulation(delay: delay)
    }()

    let content: ContentViewModel
    let receiver: USBReceiverViewModel
    let incoming: IPhoneIncomingFilesViewModel

    private init(delay: TimeInterval) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let receiverID = UUID()
        let registration = IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore())
        try registration.save(IPhoneReceiverRegistration(receiverID: receiverID, code: "123456", receiveSecret: "simulation-only", deviceName: "수신 테스트 iPhone"))
        let choices = IPhoneReceiveApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        let file = IPhoneDelivery(deliveryID: UUID(), fileName: "수신-시뮬레이션.txt", contentType: "text/plain", size: 16, sha256: String(repeating: "a", count: 64), state: .available, createdAt: Date(), expiresAt: Date().addingTimeInterval(3_600), deliveredAt: nil)
        let arrivalDate = Date().addingTimeInterval(delay)
        let preferences = USBReceiverPreferences(defaults: UserDefaults(suiteName: "ReceiveUITest.\(UUID().uuidString)")!)
        content = ContentViewModel(
            credentialStore: InMemoryCredentialStore(),
            ledger: try UploadLedger(fileURL: root.appendingPathComponent("upload-ledger.json")),
            uploader: SimulationUploader(),
            now: Date.init,
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) }
        )
        receiver = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: registration,
            bookmarkStore: USBBookmarkStore(fileURL: root.appendingPathComponent("destination.json")),
            registrar: SimulationRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "수신 테스트 iPhone",
            preferences: preferences
        )
        incoming = IPhoneIncomingFilesViewModel(
            loadPendingFiles: {
                let approved = try choices.destinations(receiverID: receiverID)
                let visible = Date() >= arrivalDate && approved[file.deliveryID] == nil
                return IPhoneIncomingSnapshot(receiverID: receiverID, files: visible ? [file] : [])
            },
            approveFiles: { id, ids, destination in
                try choices.approve(ids, receiverID: id, destination: destination)
            }
        )
    }
}

private struct SimulationUploader: UploadCoordinating {
    func upload(assetID: String, fileURL: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private struct SimulationRegistrar: IPhoneReceiverRegistering {
    func register(uploadCredential: String, deviceName: String) async throws -> IPhoneReceiverRegistration {
        throw URLError(.unsupportedURL)
    }
}
#endif
