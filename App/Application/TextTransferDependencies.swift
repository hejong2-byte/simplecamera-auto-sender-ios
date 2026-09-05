import Foundation

final class TextTransferDependencies: @unchecked Sendable {
    static let shared: TextTransferDependencies = {
        let applicationSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let textRoot = applicationSupport
            .appendingPathComponent("SimpleCameraAutoSender", isDirectory: true)
            .appendingPathComponent("TextMessages", isDirectory: true)
        let store = TextMessageStore(root: textRoot)
        let recipientStore = TextSavedRecipientStore(
            fileURL: textRoot.appendingPathComponent("saved-recipients.json")
        )
        let registrations = IPhoneReceiverRegistrationStore(
            identityStore: KeychainCredentialStore(
                account: AppConfiguration.receiverIdentityKeychainAccount
            ),
            secretStore: KeychainCredentialStore(
                account: AppConfiguration.receiveSecretKeychainAccount
            )
        )
        let service = TextTransferService(
            store: store,
            client: TextTransferClient(),
            uploadCredentials: KeychainCredentialStore(),
            registrations: registrations
        )
        return TextTransferDependencies(
            service: service,
            registrations: registrations,
            recipientStore: recipientStore
        )
    }()

    private let service: TextTransferService
    private let registrations: IPhoneReceiverRegistrationStore
    private let recipientStore: TextSavedRecipientStore

    private init(
        service: TextTransferService,
        registrations: IPhoneReceiverRegistrationStore,
        recipientStore: TextSavedRecipientStore
    ) {
        self.service = service
        self.registrations = registrations
        self.recipientStore = recipientStore
    }

    @MainActor
    func makeViewModel() -> TextTransferViewModel {
        TextTransferViewModel(
            loadOwnCode: { [registrations] in
                try registrations.load()?.identity.code
            },
            receive: { [service] in try await service.receiveOnce() },
            loadHistory: { [service] in try await service.history() },
            send: { [service] recipient, text in
                try await service.send(recipient: recipient, text: text)
            },
            retry: { [service] id in try await service.retry(id: id) },
            markRead: { [service] key in try await service.markRead(key) },
            delete: { [service] key in try await service.delete(key) },
            loadDraft: { [service] in try await service.loadDraft() },
            saveDraft: { [service] draft in try await service.saveDraft(draft) },
            loadRecipients: { [recipientStore] in try await recipientStore.load() },
            saveRecipient: { [recipientStore] code, name in
                try await recipientStore.save(code: code, name: name)
            },
            selectRecipient: { [recipientStore] code in
                try await recipientStore.select(code: code)
            },
            deleteRecipient: { [recipientStore] code in
                try await recipientStore.delete(code: code)
            }
        )
    }
}
