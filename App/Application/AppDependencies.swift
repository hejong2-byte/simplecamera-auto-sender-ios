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
            manualTransferService: manualTransferService
        )
    }()

    let credentialStore: CredentialStore
    let uploader: BackgroundUploadCoordinator
    let syncService: PhotoSyncService
    let manualTransferService: ManualMediaTransferService

    private init(
        credentialStore: CredentialStore,
        uploader: BackgroundUploadCoordinator,
        syncService: PhotoSyncService,
        manualTransferService: ManualMediaTransferService
    ) {
        self.credentialStore = credentialStore
        self.uploader = uploader
        self.syncService = syncService
        self.manualTransferService = manualTransferService
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
