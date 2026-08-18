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
        return AppDependencies(
            credentialStore: credentialStore,
            uploader: uploader,
            syncService: syncService
        )
    }()

    let credentialStore: CredentialStore
    let uploader: BackgroundUploadCoordinator
    let syncService: PhotoSyncService

    private init(
        credentialStore: CredentialStore,
        uploader: BackgroundUploadCoordinator,
        syncService: PhotoSyncService
    ) {
        self.credentialStore = credentialStore
        self.uploader = uploader
        self.syncService = syncService
    }
}
