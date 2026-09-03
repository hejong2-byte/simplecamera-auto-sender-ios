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
        let usbStateDirectory = applicationSupport
            .appendingPathComponent("SimpleCameraAutoSender", isDirectory: true)
            .appendingPathComponent("USBReceiver", isDirectory: true)
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
            fileURL: usbStateDirectory.appendingPathComponent("destination.json")
        )
        let ledger = try! USBReceiveLedger(
            fileURL: usbStateDirectory.appendingPathComponent("ledger.json")
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
        let approvalStore = IPhoneReceiveApprovalStore(
            fileURL: stateDirectory.appendingPathComponent("receive-approvals.json")
        )
        let outcomeStore = IPhoneReceiveOutcomeStore(
            fileURL: stateDirectory.appendingPathComponent("latest-receive-outcome.json")
        )
        let client = IPhoneReceiverClient(
            transport: PolicyIPhoneReceiverTransport(preferences: preferences)
        )
        let localClient = IPhoneReceiverClient(
            transport: PolicyIPhoneReceiverTransport(preferences: preferences),
            allowedDeliveryIDs: { receiverID in
                try approvalStore.allowedDeliveryIDs(
                    receiverID: receiverID,
                    destination: .iphoneLocal,
                    resuming: Set(jobStore.load().jobs.map { $0.delivery.deliveryID })
                )
            }
        )
        let usbClient = IPhoneReceiverClient(
            transport: PolicyIPhoneReceiverTransport(preferences: preferences),
            allowedDeliveryIDs: { receiverID in
                try approvalStore.allowedDeliveryIDs(
                    receiverID: receiverID,
                    destination: .usb,
                    resuming: Set(ledger.allCheckpoints().map(\.deliveryID))
                )
            }
        )
        let progressStore = USBReceiveProgressStore()
        let exportProgressStore = USBReceiveProgressStore()
        let directUSBService = USBReceiveService(
            client: usbClient,
            ledger: ledger,
            credentials: { try registrationStore.load() },
            destination: { try bookmarkStore.resolve() },
            progressStore: progressStore
        )
        let backgroundSession = BackgroundIPhoneReceiveSession.shared
        let localEngine = IPhoneLocalReceiveEngine(
            client: localClient,
            scheduler: backgroundSession,
            jobStore: jobStore,
            catalog: catalog,
            credentials: { try registrationStore.load() },
            progressStore: progressStore
        )
        backgroundSession.bind(sink: localEngine)
        let exporter = IPhoneUSBExportService(
            deletionStore: deletionStore,
            progressStore: exportProgressStore
        )
        let dependencies = USBReceiverDependencies(
            registrationStore: registrationStore,
            bookmarkStore: bookmarkStore,
            preferences: preferences,
            approvalStore: approvalStore,
            jobStore: jobStore,
            ledger: ledger,
            client: client,
            directUSBService: directUSBService,
            localEngine: localEngine,
            catalog: catalog,
            exporter: exporter,
            deletionStore: deletionStore,
            progressStore: progressStore,
            exportProgressStore: exportProgressStore,
            outcomeStore: outcomeStore
        )
        Task { await localEngine.restore() }
        return dependencies
    }()

    private let registrationStore: IPhoneReceiverRegistrationStore
    private let bookmarkStore: USBBookmarkStore
    private let preferences: USBReceiverPreferences
    private let approvalStore: IPhoneReceiveApprovalStore
    private let jobStore: IPhoneLocalReceiveJobStore
    private let ledger: USBReceiveLedger
    private let client: IPhoneReceiverClient
    private let directUSBService: USBReceiveService
    private let localEngine: IPhoneLocalReceiveEngine
    private let catalog: IPhoneReceivedFileCatalog
    private let exporter: IPhoneUSBExportService
    private let deletionStore: IPhoneUSBDeletionDecisionStore
    private let progressStore: USBReceiveProgressStore
    private let exportProgressStore: USBReceiveProgressStore
    private let outcomeStore: IPhoneReceiveOutcomeStore

    private init(
        registrationStore: IPhoneReceiverRegistrationStore,
        bookmarkStore: USBBookmarkStore,
        preferences: USBReceiverPreferences,
        approvalStore: IPhoneReceiveApprovalStore,
        jobStore: IPhoneLocalReceiveJobStore,
        ledger: USBReceiveLedger,
        client: IPhoneReceiverClient,
        directUSBService: USBReceiveService,
        localEngine: IPhoneLocalReceiveEngine,
        catalog: IPhoneReceivedFileCatalog,
        exporter: IPhoneUSBExportService,
        deletionStore: IPhoneUSBDeletionDecisionStore,
        progressStore: USBReceiveProgressStore,
        exportProgressStore: USBReceiveProgressStore,
        outcomeStore: IPhoneReceiveOutcomeStore
    ) {
        self.registrationStore = registrationStore
        self.bookmarkStore = bookmarkStore
        self.preferences = preferences
        self.approvalStore = approvalStore
        self.jobStore = jobStore
        self.ledger = ledger
        self.client = client
        self.directUSBService = directUSBService
        self.localEngine = localEngine
        self.catalog = catalog
        self.exporter = exporter
        self.deletionStore = deletionStore
        self.progressStore = progressStore
        self.exportProgressStore = exportProgressStore
        self.outcomeStore = outcomeStore
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
            pendingDeliveryIDs: { [client, registrationStore, approvalStore, ledger, jobStore] in
                guard let credentials = try registrationStore.load() else { return [] }
                let deliveries = try await client.list(
                    receiverID: credentials.identity.receiverID,
                    receiveSecret: credentials.secret
                )
                let approved = try approvalStore.destinations(receiverID: credentials.identity.receiverID)
                let existing = Set(ledger.allCheckpoints().map(\.deliveryID))
                    .union(try jobStore.load().jobs.map { $0.delivery.deliveryID })
                return Set(deliveries.compactMap {
                    [.available, .leased].contains($0.state)
                        && (approved[$0.deliveryID] != nil || existing.contains($0.deliveryID))
                        ? $0.deliveryID : nil
                })
            },
            approveLocalFallback: { [approvalStore, registrationStore] ids in
                guard let credentials = try registrationStore.load() else {
                    throw USBReceiveServiceError.missingRegistration
                }
                try approvalStore.approve(ids, receiverID: credentials.identity.receiverID, destination: .iphoneLocal)
            },
            storedFiles: { [catalog] in try catalog.refresh() },
            previewStoredFile: { [catalog] in try catalog.previewURL(for: $0) },
            deleteStoredFiles: { [catalog, jobStore] files in
                let protectedNames = Set(try jobStore.load().jobs
                    .filter { $0.stage != .completed }
                    .compactMap(\.finalFileName))
                return catalog.delete(files, protectedFileNames: protectedNames)
            },
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
            exportProgressUpdates: { [exportProgressStore] in exportProgressStore.updates() },
            loadOutcome: { [outcomeStore] receiverID in
                outcomeStore.load(receiverID: receiverID)
            },
            saveOutcome: { [outcomeStore] outcome in
                try outcomeStore.save(outcome)
            },
            clearOutcome: { [outcomeStore] receiverID in
                try outcomeStore.clear(receiverID: receiverID)
            },
            defaultDeviceName: UIDevice.current.name,
            preferences: preferences
        )
    }

    @MainActor
    func makeIncomingFilesViewModel() -> IPhoneIncomingFilesViewModel {
        IPhoneIncomingFilesViewModel(
            loadPendingFiles: { [client, registrationStore, approvalStore, ledger, jobStore] in
                guard let credentials = try registrationStore.load() else {
                    return IPhoneIncomingSnapshot(receiverID: nil, files: [])
                }
                let receiverID = credentials.identity.receiverID
                let files = try await client.list(receiverID: receiverID, receiveSecret: credentials.secret)
                let current = try registrationStore.load()?.identity.receiverID
                guard current == receiverID else {
                    return IPhoneIncomingSnapshot(receiverID: current, files: [])
                }
                let approved = try approvalStore.destinations(receiverID: receiverID)
                let existing = Set(ledger.allCheckpoints().map(\.deliveryID))
                    .union(try jobStore.load().jobs.map { $0.delivery.deliveryID })
                return IPhoneIncomingSnapshot(receiverID: receiverID, files: files.filter {
                    approved[$0.deliveryID] == nil && !existing.contains($0.deliveryID)
                })
            },
            approveFiles: { [approvalStore, registrationStore] receiverID, ids, destination in
                guard try registrationStore.load()?.identity.receiverID == receiverID else {
                    throw USBReceiveServiceError.missingRegistration
                }
                try approvalStore.approve(ids, receiverID: receiverID, destination: destination)
            }
        )
    }
}
