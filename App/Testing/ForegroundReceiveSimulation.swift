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
        let outcomeIndex = arguments.firstIndex(of: "--ui-test-receive-outcome")
        let outcome = outcomeIndex.flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        return try! ForegroundReceiveSimulation(
            delay: delay, outcome: outcome,
            withStoredFiles: arguments.contains("--ui-test-stored-files")
        )
    }()

    let content: ContentViewModel
    let receiver: USBReceiverViewModel
    let incoming: IPhoneIncomingFilesViewModel
    let filePicker: KakaoFilePickerModel
    let text: TextTransferViewModel

    private init(delay: TimeInterval, outcome: String?, withStoredFiles: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: root.appendingPathComponent("Received", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("Staging", isDirectory: true),
            recordsFileURL: root.appendingPathComponent("records.json")
        )
        if withStoredFiles {
            for name in ["delete-me.txt", "keep-me.txt"] {
                try Data("simulated local file".utf8).write(
                    to: catalog.receivedDirectory.appendingPathComponent(name)
                )
            }
        }
        let receiverID = UUID()
        let registration = IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore())
        try registration.save(IPhoneReceiverRegistration(receiverID: receiverID, code: "123456", receiveSecret: "simulation-only", deviceName: "수신 테스트 iPhone"))
        let choices = IPhoneReceiveApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        let file = IPhoneDelivery(deliveryID: UUID(), fileName: "수신-시뮬레이션.txt", contentType: "text/plain", size: 16, sha256: String(repeating: "a", count: 64), state: .available, createdAt: Date(), expiresAt: Date().addingTimeInterval(3_600), deliveredAt: nil)
        let arrivalDate = Date().addingTimeInterval(delay)
        let preferences = USBReceiverPreferences(defaults: UserDefaults(suiteName: "ReceiveUITest.\(UUID().uuidString)")!)
        let receiveOutcome: IPhoneReceiveOutcome?
        switch outcome {
        case "saved":
            receiveOutcome = IPhoneReceiveOutcome(
                receiverID: receiverID,
                kind: .saved,
                destination: .iphoneLocal,
                fileName: "업무자료.zip",
                totalCount: 1,
                completedCount: 1,
                message: "iPhone 저장 완료",
                occurredAt: Date(timeIntervalSince1970: 1_787_990_400)
            )
        case "error":
            receiveOutcome = IPhoneReceiveOutcome(
                receiverID: receiverID,
                kind: .failed,
                destination: .iphoneLocal,
                fileName: nil,
                totalCount: 0,
                completedCount: 0,
                message: "서버 오류: 파일 정보를 확인하지 못했습니다.",
                occurredAt: Date(timeIntervalSince1970: 1_787_990_400)
            )
        default:
            receiveOutcome = nil
        }
        filePicker = KakaoFilePickerModel(store: KakaoFolderStore(fileURL: root.appendingPathComponent("kakao-folder.json")))
        let textStore = TextMessageStore(root: root.appendingPathComponent("TextMessages", isDirectory: true))
        text = TextTransferViewModel(
            loadOwnCode: { "123456" },
            receive: {
                TextReceiveSummary(received: 0, duplicates: 0, rejected: 0, pendingACK: 0)
            },
            loadHistory: { try await textStore.history() },
            send: { recipient, body in
                let message = try await textStore.queueOutgoing(
                    sender: "123456",
                    recipient: recipient,
                    text: body
                )
                try await textStore.markServerDelivered(id: message.envelope.id)
                var delivered = message
                delivered.status = .serverDelivered
                return delivered
            },
            retry: { id in
                try await textStore.markServerDelivered(id: id)
                guard let message = try await textStore.history().first(where: {
                    $0.key.direction == .sent && $0.envelope.id == id
                }) else {
                    throw TextTransferServiceError.messageNotFound
                }
                return message
            },
            markRead: { key in try await textStore.markRead(key) },
            delete: { key in try await textStore.delete(key) },
            loadDraft: { try await textStore.loadDraft() },
            saveDraft: { draft in try await textStore.saveDraft(draft) }
        )
        let uploadCredential = InMemoryCredentialStore()
        try uploadCredential.save("simulation-only")
        content = ContentViewModel(
            credentialStore: uploadCredential,
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
            receiveOnce: {
                let approved = try choices.allowedDeliveryIDs(receiverID: receiverID, destination: .usb)
                if !approved.isEmpty { throw USBReceiveServiceError.missingDestination }
                return USBReceiveSummary(discovered: 0, completed: 0)
            },
            pendingDeliveryIDs: { Set(try choices.destinations(receiverID: receiverID).keys) },
            approveLocalFallback: { ids in
                try choices.approve(ids, receiverID: receiverID, destination: .iphoneLocal)
            },
            storedFiles: { try catalog.refresh() },
            previewStoredFile: { try catalog.previewURL(for: $0) },
            deleteStoredFiles: { files in catalog.delete(files) },
            progressUpdates: { AsyncStream { $0.finish() } },
            loadOutcome: { id in
                receiveOutcome?.receiverID == id ? receiveOutcome : nil
            },
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
