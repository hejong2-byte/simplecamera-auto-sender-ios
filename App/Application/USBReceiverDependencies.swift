import Foundation
import UIKit

final class USBReceiverDependencies: @unchecked Sendable {
    static let shared: USBReceiverDependencies = {
        let fileManager = FileManager.default
        let applicationSupport = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let stateDirectory = applicationSupport
            .appendingPathComponent("SimpleCameraAutoSender", isDirectory: true)
            .appendingPathComponent("PCFileReceiver", isDirectory: true)
        let documents = try! fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
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
            fileURL: stateDirectory.appendingPathComponent("usb-ledger.json")
        )
        let catalog = try! IPhoneReceivedFileCatalog(
            receivedDirectory: documents.appendingPathComponent("받은 파일", isDirectory: true),
            stagingDirectory: stateDirectory.appendingPathComponent(
                "ReceiveStaging",
                isDirectory: true
            ),
            recordsFileURL: stateDirectory.appendingPathComponent("received-records.json")
        )
        let jobStore = try! IPhoneLocalReceiveJobStore(
            fileURL: stateDirectory.appendingPathComponent("local-jobs.json")
        )
        let deletionStore = try! IPhoneUSBDeletionDecisionStore(
            fileURL: stateDirectory.appendingPathComponent("deletion-decisions.json")
        )
        let preferences = USBReceiverPreferences()
        let client = IPhoneReceiverClient(
            transport: PolicyIPhoneReceiverTransport(preferences: preferences)
        )
        let progressStore = USBReceiveProgressStore()
        let directUSBService = USBReceiveService(
            client: client,
            ledger: ledger,
            credentials: { try registrationStore.load() },
            destination: { try bookmarkStore.resolve() },
            progressStore: progressStore
        )
        let backgroundSession = BackgroundIPhoneReceiveSession.shared
        let localEngine = IPhoneLocalReceiveEngine(
            client: client,
            scheduler: backgroundSession,
            jobStore: jobStore,
            catalog: catalog,
            credentials: { try registrationStore.load() },
            automaticDiscoveryAllowed: { preferences.selectedDestination == .iphoneLocal },
            progressStore: progressStore
        )
        backgroundSession.bind(sink: localEngine)
        let exporter = IPhoneUSBExportService(
            deletionStore: deletionStore,
            progressStore: progressStore
        )
        let dependencies = USBReceiverDependencies(
            registrationStore: registrationStore,
            bookmarkStore: bookmarkStore,
            preferences: preferences,
            client: client,
            directUSBService: directUSBService,
            localEngine: localEngine,
            catalog: catalog,
            exporter: exporter,
            deletionStore: deletionStore,
            progressStore: progressStore
        )
        Task { await localEngine.restore() }
        return dependencies
    }()

    private let registrationStore: IPhoneReceiverRegistrationStore
    private let bookmarkStore: USBBookmarkStore
    private let preferences: USBReceiverPreferences
    private let client: IPhoneReceiverClient
    private let directUSBService: USBReceiveService
    private let localEngine: IPhoneLocalReceiveEngine
    private let catalog: IPhoneReceivedFileCatalog
    private let exporter: IPhoneUSBExportService
    private let deletionStore: IPhoneUSBDeletionDecisionStore
    private let progressStore: USBReceiveProgressStore

    private init(
        registrationStore: IPhoneReceiverRegistrationStore,
        bookmarkStore: USBBookmarkStore,
        preferences: USBReceiverPreferences,
        client: IPhoneReceiverClient,
        directUSBService: USBReceiveService,
        localEngine: IPhoneLocalReceiveEngine,
        catalog: IPhoneReceivedFileCatalog,
        exporter: IPhoneUSBExportService,
        deletionStore: IPhoneUSBDeletionDecisionStore,
        progressStore: USBReceiveProgressStore
    ) {
        self.registrationStore = registrationStore
        self.bookmarkStore = bookmarkStore
        self.preferences = preferences
        self.client = client
        self.directUSBService = directUSBService
        self.localEngine = localEngine
        self.catalog = catalog
        self.exporter = exporter
        self.deletionStore = deletionStore
        self.progressStore = progressStore
    }

    func restoreLocalReceiver() async {
        await localEngine.restore()
    }

    @MainActor
    func makeViewModel() -> USBReceiverViewModel {
        USBReceiverViewModel(
            uploadCredentialStore: KeychainCredentialStore(),
            registrationStore: registrationStore,
            bookmarkStore: bookmarkStore,
            registrar: client,
            receiveOnce: { [directUSBService] in
                try await directUSBService.runOnce()
            },
            receiveLocalOnce: { [localEngine] in
                try await localEngine.discoverAndSchedule(force: true)
            },
            pendingDeliveryIDs: { [client, registrationStore] in
                guard let credentials = try registrationStore.load() else { return [] }
                let deliveries = try await client.list(
                    receiverID: credentials.identity.receiverID,
                    receiveSecret: credentials.secret
                )
                return Set(deliveries.compactMap {
                    [.available, .leased].contains($0.state) ? $0.deliveryID : nil
                })
            },
            storedFiles: { [catalog] in try catalog.refresh() },
            exportFiles: { [exporter] files, destination in
                await exporter.export(files, to: destination)
            },
            pendingDeletionDecisions: { [deletionStore] in deletionStore.pending() },
            keepOriginals: { [exporter] ids in try await exporter.keep(decisionIDs: ids) },
            deleteOriginals: { [exporter] ids in
                await exporter.delete(decisionIDs: ids)
            },
            refreshFeatures: { [client, registrationStore] in
                guard let credentials = try registrationStore.load() else { return }
                try await client.updateFeatures(
                    receiverID: credentials.identity.receiverID,
                    receiveSecret: credentials.secret,
                    features: .current
                )
            },
            progressUpdates: { [progressStore] in progressStore.updates() },
            defaultDeviceName: UIDevice.current.name,
            preferences: preferences
        )
    }
}
