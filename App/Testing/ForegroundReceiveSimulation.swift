#if targetEnvironment(simulator)
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
            withStoredFiles: arguments.contains("--ui-test-stored-files"),
            withTextMessage: arguments.contains("--ui-test-text-message"),
            withSavedTextRecipient: arguments.contains("--ui-test-text-recipient"),
            withZIP: arguments.contains("--ui-test-incoming-zip"),
            withMultipleIncoming: arguments.contains("--ui-test-multiple-incoming"),
            withStorageManagement: arguments.contains("--ui-test-storage-management")
        )
    }()

    let content: ContentViewModel
    let receiver: USBReceiverViewModel
    let incoming: IPhoneIncomingFilesViewModel
    let filePicker: KakaoFilePickerModel
    let text: TextTransferViewModel

    private init(
        delay: TimeInterval,
        outcome: String?,
        withStoredFiles: Bool,
        withTextMessage: Bool,
        withSavedTextRecipient: Bool,
        withZIP: Bool,
        withMultipleIncoming: Bool,
        withStorageManagement: Bool
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: root.appendingPathComponent("Received", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("Staging", isDirectory: true),
            recordsFileURL: root.appendingPathComponent("records.json")
        )
        if withStoredFiles {
            for name in ["delete-me.txt", "keep-me.txt", "stored.zip"] {
                try Data("simulated local file".utf8).write(
                    to: catalog.receivedDirectory.appendingPathComponent(name)
                )
            }
        }
        let receiverID = UUID()
        let registration = IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore())
        try registration.save(IPhoneReceiverRegistration(receiverID: receiverID, code: "123456", receiveSecret: "simulation-only", deviceName: "수신 테스트 iPhone"))
        let choices = IPhoneReceiveApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        let files: [IPhoneDelivery]
        if withMultipleIncoming {
            let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
            files = [
                IPhoneDelivery(
                    deliveryID: firstID, fileName: "first.txt",
                    contentType: "text/plain", size: 16,
                    sha256: String(repeating: "a", count: 64), state: .available,
                    createdAt: Date().addingTimeInterval(-10),
                    expiresAt: Date().addingTimeInterval(3_590), deliveredAt: nil
                ),
                IPhoneDelivery(
                    deliveryID: secondID, fileName: "second.txt",
                    contentType: "text/plain", size: 32,
                    sha256: String(repeating: "b", count: 64), state: .available,
                    createdAt: Date(), expiresAt: Date().addingTimeInterval(3_600),
                    deliveredAt: nil
                )
            ]
        } else {
            files = [IPhoneDelivery(
                deliveryID: UUID(),
                fileName: withZIP ? "수신-시뮬레이션.zip" : "수신-시뮬레이션.txt",
                contentType: withZIP ? "application/zip" : "text/plain",
                size: 16, sha256: String(repeating: "a", count: 64),
                state: .available, createdAt: Date(),
                expiresAt: Date().addingTimeInterval(3_600), deliveredAt: nil
            )]
        }
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
        let textRoot = root.appendingPathComponent("TextMessages", isDirectory: true)
        if withTextMessage { try Self.seedTextMessage(at: textRoot) }
        if withSavedTextRecipient { try Self.seedTextRecipient(at: textRoot) }
        let textStore = TextMessageStore(root: textRoot)
        let textRecipientStore = TextSavedRecipientStore(
            fileURL: textRoot.appendingPathComponent("saved-recipients.json")
        )
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
            saveDraft: { draft in try await textStore.saveDraft(draft) },
            loadRecipients: { try await textRecipientStore.load() },
            saveRecipient: { code, name in
                try await textRecipientStore.save(code: code, name: name)
            },
            selectRecipient: { code in try await textRecipientStore.select(code: code) },
            deleteRecipient: { code in try await textRecipientStore.delete(code: code) }
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
        let bookmarkStore = USBBookmarkStore(
            fileURL: root.appendingPathComponent("destination.json"),
            codec: SimulationUSBBookmarkCodec()
        )
        if withStorageManagement {
            let usbRoot = root.appendingPathComponent("SD CARD", isDirectory: true)
            let nested = usbRoot.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("visible".utf8).write(to: usbRoot.appendingPathComponent("visible.bin"))
            try Data("inside".utf8).write(to: nested.appendingPathComponent("inside.bin"))
            try bookmarkStore.save(
                folderURL: usbRoot,
                volumeID: "simulation-volume",
                displayName: "SD CARD",
                formatDescription: "ExFAT"
            )
            if outcome == "usb-disconnect" {
                // Only this simulator fixture owns this temporary mock volume.
                Task.detached {
                    try? await Task.sleep(for: .seconds(45))
                    try? FileManager.default.removeItem(at: usbRoot)
                }
            }
        }
        let cleanup = USBFolderCleanupService(
            volumeIdentity: { _ in "simulation-volume" },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        receiver = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: registration,
            bookmarkStore: bookmarkStore,
            checkUSBAvailability: { destination in
                USBFolderAvailability.check(destination, startAccessing: { _ in true }, stopAccessing: { _ in })
            },
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
            inspectUSBFolder: { destination in
                try await cleanup.inspect(destination)
            },
            deleteUSBFolderContents: { destination, summary in
                try await cleanup.deleteAllContents(of: destination, matching: summary)
            },
            progressUpdates: { AsyncStream { continuation in
                if outcome == "downloading", let file = files.first {
                    continuation.yield(USBReceiveProgress(
                        stage: .downloading, destination: .iphoneLocal,
                        deliveryID: file.deliveryID, fileName: file.fileName,
                        currentIndex: 1, totalCount: 1, completedCount: 0,
                        bytesReceived: 1, totalBytes: file.size,
                        startedAt: Date(), expiresAt: file.expiresAt, errorMessage: nil
                    ))
                }
                continuation.finish()
            } },
            loadOutcome: { id in
                receiveOutcome?.receiverID == id ? receiveOutcome : nil
            },
            defaultDeviceName: "수신 테스트 iPhone",
            preferences: preferences
        )
        incoming = IPhoneIncomingFilesViewModel(
            loadPendingFiles: {
                let visible = Date() >= arrivalDate
                return IPhoneIncomingSnapshot(receiverID: receiverID, files: visible ? files : [])
            },
            approveFiles: { id, ids, decision in
                try choices.approve(ids, receiverID: id, decision: decision)
            }
        )
    }

    private static func seedTextMessage(at root: URL) throws {
        let envelope = try TextMessageEnvelope.make(
            sender: "654321",
            recipient: "123456",
            text: "  PC에서 받은 텍스트\n둘째 줄  ",
            id: UUID(uuidString: "123e4567-e89b-42d3-a456-426614174333")!,
            now: Date(timeIntervalSince1970: 1_778_115_723)
        )
        let body = try envelope.encoded()
        let message = TextStoredMessage(
            key: TextMessageKey(direction: .received, id: envelope.id),
            envelope: envelope,
            bodySHA256: TextDigest.hex(body),
            status: .received,
            readAt: nil
        )
        let messages = root.appendingPathComponent("messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let file = messages.appendingPathComponent(
            "received-\(envelope.id.uuidString.lowercased()).json"
        )
        try JSONEncoder().encode(message).write(to: file, options: .atomic)
    }

    private static func seedTextRecipient(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = TextSavedRecipientState(
            recipients: [TextSavedRecipient(code: "709592", name: "행정망 PC")],
            selectedCode: nil
        )
        try JSONEncoder().encode(state).write(
            to: root.appendingPathComponent("saved-recipients.json"),
            options: .atomic
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

private struct SimulationUSBBookmarkCodec: USBBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8), !path.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return USBBookmarkResolution(
            url: URL(fileURLWithPath: path, isDirectory: true),
            isStale: false
        )
    }
}
#endif
