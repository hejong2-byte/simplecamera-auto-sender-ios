import Foundation
import UIKit

final class USBReceiverDependencies: @unchecked Sendable {
    static let shared: USBReceiverDependencies = {
        let root = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let stateDirectory = root
            .appendingPathComponent("SimpleCameraAutoSender", isDirectory: true)
            .appendingPathComponent("USBReceiver", isDirectory: true)
        let registrationStore = IPhoneReceiverRegistrationStore(
            identityStore: KeychainCredentialStore(
                account: AppConfiguration.receiverIdentityKeychainAccount
            ),
            secretStore: KeychainCredentialStore(
                account: AppConfiguration.receiveSecretKeychainAccount
            )
        )
        let bookmarkStore = USBBookmarkStore(
            fileURL: stateDirectory.appendingPathComponent("destination.json")
        )
        let ledger = try! USBReceiveLedger(
            fileURL: stateDirectory.appendingPathComponent("ledger.json")
        )
        let preferences = USBReceiverPreferences()
        let client = IPhoneReceiverClient(
            transport: PolicyIPhoneReceiverTransport(preferences: preferences)
        )
        let progressStore = USBReceiveProgressStore()
        let service = USBReceiveService(
            client: client,
            ledger: ledger,
            credentials: { try registrationStore.load() },
            destination: { try bookmarkStore.resolve() },
            progressStore: progressStore
        )
        return USBReceiverDependencies(
            registrationStore: registrationStore,
            bookmarkStore: bookmarkStore,
            preferences: preferences,
            client: client,
            service: service,
            progressStore: progressStore
        )
    }()

    private let registrationStore: IPhoneReceiverRegistrationStore
    private let bookmarkStore: USBBookmarkStore
    private let preferences: USBReceiverPreferences
    private let client: IPhoneReceiverClient
    private let service: USBReceiveService
    private let progressStore: USBReceiveProgressStore

    private init(
        registrationStore: IPhoneReceiverRegistrationStore,
        bookmarkStore: USBBookmarkStore,
        preferences: USBReceiverPreferences,
        client: IPhoneReceiverClient,
        service: USBReceiveService,
        progressStore: USBReceiveProgressStore
    ) {
        self.registrationStore = registrationStore
        self.bookmarkStore = bookmarkStore
        self.preferences = preferences
        self.client = client
        self.service = service
        self.progressStore = progressStore
    }

    @MainActor
    func makeViewModel() -> USBReceiverViewModel {
        USBReceiverViewModel(
            uploadCredentialStore: KeychainCredentialStore(),
            registrationStore: registrationStore,
            bookmarkStore: bookmarkStore,
            registrar: client,
            receiveOnce: { [service] in try await service.runOnce() },
            progressUpdates: { [progressStore] in progressStore.updates() },
            defaultDeviceName: UIDevice.current.name,
            preferences: preferences
        )
    }
}
