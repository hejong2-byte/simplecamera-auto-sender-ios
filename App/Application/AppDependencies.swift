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
        let syncService = PhotoSyncService(
            credentialStore: credentialStore,
            photoSource: PhotoKitAssetSource(),
            metadataMatcher: SimpleCameraMetadataMatcher(),
            ledger: uploader.ledger,
            uploader: uploader,
            uploadsDirectory: uploadsDirectory
        )
        let manualTransferService = ManualMediaTransferService(
            source: PhotoKitManualMediaSource(),
            ledger: uploader.ledger,
            uploader: uploader,
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
            manualTransferEngine: manualTransferEngine
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

    private init(
        credentialStore: CredentialStore,
        uploader: BackgroundUploadCoordinator,
        syncService: PhotoSyncService,
        manualTransferService: ManualMediaTransferService,
        manualJobStore: ManualTransferJobStore,
        backgroundCompletionRegistry: BackgroundSessionCompletionRegistry,
        backgroundManualSession: BackgroundManualUploadSession,
        manualTransferEngine: ManualBackgroundTransferEngine
    ) {
        self.credentialStore = credentialStore
        self.uploader = uploader
        self.syncService = syncService
        self.manualTransferService = manualTransferService
        self.manualJobStore = manualJobStore
        self.backgroundCompletionRegistry = backgroundCompletionRegistry
        self.backgroundManualSession = backgroundManualSession
        self.manualTransferEngine = manualTransferEngine
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
            manualSend: { [manualTransferService] selection, kind in
                await manualTransferService.send(selection: selection, kind: kind)
            }
        )
    }
}
