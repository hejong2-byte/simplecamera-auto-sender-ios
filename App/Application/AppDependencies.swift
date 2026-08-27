import Foundation

final class AppDependencies: @unchecked Sendable {
    static let shared: AppDependencies = {
        let credentialStore = KeychainCredentialStore()
        let uploader = BackgroundUploadCoordinator.shared
        let root = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let uploadsDirectory = root
            .appendingPathComponent("SimpleCameraAutoSender", isDirectory: true)
            .appendingPathComponent("Uploads", isDirectory: true)
        let manualStateDirectory = root
            .appendingPathComponent("SimpleCameraAutoSender", isDirectory: true)
            .appendingPathComponent("ManualTransfers", isDirectory: true)
        let manualJobStore = ManualTransferJobStore(
            fileURL: manualStateDirectory.appendingPathComponent("queue.json")
        )
        let backgroundCompletionRegistry = BackgroundSessionCompletionRegistry.shared
        let backgroundManualSession = BackgroundManualUploadSession(
            completionRegistry: backgroundCompletionRegistry
        )
        let manualTransferEngine = ManualBackgroundTransferEngine(
            scheduler: backgroundManualSession,
            jobStore: manualJobStore,
            credentialStore: credentialStore
        )
        backgroundManualSession.bind(engine: manualTransferEngine)
        let automaticProgressStore = AutomaticTransferProgressStore()
        let syncService = PhotoSyncService(
            credentialStore: credentialStore,
            photoSource: PhotoKitAssetSource(),
            metadataMatcher: SimpleCameraMetadataMatcher(),
            ledger: uploader.ledger,
            uploader: uploader,
            uploadsDirectory: uploadsDirectory,
            automaticProgressStore: automaticProgressStore
        )
        let manualTransferService = ManualMediaTransferService(
            source: PhotoKitManualMediaSource(),
            jobStore: manualJobStore,
            engine: manualTransferEngine,
            exportDirectory: uploadsDirectory
                .appendingPathComponent("Manual", isDirectory: true)
        )
        return AppDependencies(
            credentialStore: credentialStore,
            uploader: uploader,
            syncService: syncService,
            manualTransferService: manualTransferService,
            manualJobStore: manualJobStore,
            backgroundCompletionRegistry: backgroundCompletionRegistry,
            backgroundManualSession: backgroundManualSession,
            manualTransferEngine: manualTransferEngine,
            automaticProgressStore: automaticProgressStore
        )
    }()

    let credentialStore: CredentialStore
    let uploader: BackgroundUploadCoordinator
    let syncService: PhotoSyncService
    let manualTransferService: ManualMediaTransferService
    let manualJobStore: ManualTransferJobStore
    let backgroundCompletionRegistry: BackgroundSessionCompletionRegistry
    let backgroundManualSession: BackgroundManualUploadSession
    let manualTransferEngine: ManualBackgroundTransferEngine
    let automaticProgressStore: AutomaticTransferProgressStore

    private init(
        credentialStore: CredentialStore,
        uploader: BackgroundUploadCoordinator,
        syncService: PhotoSyncService,
        manualTransferService: ManualMediaTransferService,
        manualJobStore: ManualTransferJobStore,
        backgroundCompletionRegistry: BackgroundSessionCompletionRegistry,
        backgroundManualSession: BackgroundManualUploadSession,
        manualTransferEngine: ManualBackgroundTransferEngine,
        automaticProgressStore: AutomaticTransferProgressStore
    ) {
        self.credentialStore = credentialStore
        self.uploader = uploader
        self.syncService = syncService
        self.manualTransferService = manualTransferService
        self.manualJobStore = manualJobStore
        self.backgroundCompletionRegistry = backgroundCompletionRegistry
        self.backgroundManualSession = backgroundManualSession
        self.manualTransferEngine = manualTransferEngine
        self.automaticProgressStore = automaticProgressStore
        Task { await manualTransferEngine.restore() }
    }

    @MainActor
    func makeContentViewModel() -> ContentViewModel {
        ContentViewModel(
            credentialStore: credentialStore,
            ledger: uploader.ledger,
            uploader: uploader,
            now: Date.init,
            send: { [syncService] trigger in
                try await syncService.run(trigger: trigger)
            },
            manualEnqueue: { [manualTransferService] selection, kind in
                await manualTransferService.enqueue(selection: selection, kind: kind)
            },
            manualUpdates: { [manualTransferService] in
                await manualTransferService.updates()
            },
            automaticUpdates: { [automaticProgressStore] in
                automaticProgressStore.updates()
            }
        )
    }
}
