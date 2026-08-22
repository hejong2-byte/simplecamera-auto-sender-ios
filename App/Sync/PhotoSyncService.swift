import Foundation

enum SyncTrigger: Sendable {
    case automation
    case manual
    case retry
}

struct SyncEnqueueSummary: Sendable, Equatable {
    let discovered: Int
    let queued: Int
    let failed: Int
}

enum PhotoSyncError: Error {
    case monitoringNotEnabled
}

actor PhotoSyncService {
    private let credentialStore: CredentialStore
    private let photoSource: PhotoAssetSourcing
    private let ledger: UploadLedger
    private let uploader: UploadCoordinating
    private let uploadsDirectory: URL
    private let scanDelaysNanoseconds: [UInt64]
    private var inFlight: Task<SyncEnqueueSummary, Error>?

    init(
        credentialStore: CredentialStore,
        photoSource: PhotoAssetSourcing,
        ledger: UploadLedger,
        uploader: UploadCoordinating,
        uploadsDirectory: URL,
        scanDelaysNanoseconds: [UInt64] = [0, 2_000_000_000, 3_000_000_000]
    ) {
        self.credentialStore = credentialStore
        self.photoSource = photoSource
        self.ledger = ledger
        self.uploader = uploader
        self.uploadsDirectory = uploadsDirectory
        self.scanDelaysNanoseconds = scanDelaysNanoseconds
    }

    func run(trigger: SyncTrigger) async throws -> SyncEnqueueSummary {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { [self] in
            try await performRun(trigger: trigger)
        }
        inFlight = task
        do {
            let result = try await task.value
            inFlight = nil
            return result
        } catch {
            inFlight = nil
            throw error
        }
    }

    private func performRun(trigger: SyncTrigger) async throws -> SyncEnqueueSummary {
        guard let credential = try credentialStore.load(),
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UploadConfigurationError.missingCredential
        }
        guard let baseline = try await ledger.allPhotosBaseline() else {
            throw PhotoSyncError.monitoringNotEnabled
        }
        guard !uploader.authenticationBlocked() else {
            throw UploadConfigurationError.authenticationBlocked
        }

        try FileManager.default.createDirectory(
            at: uploadsDirectory,
            withIntermediateDirectories: true
        )

        var discoveredIDs = Set<String>()
        var discovered = 0
        var queued = 0
        var failed = 0

        for delay in scanDelaysNanoseconds {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            let candidates = try await photoSource.candidates(
                createdAfter: baseline.addingTimeInterval(-60)
            )

            for candidate in candidates {
                if discoveredIDs.insert(candidate.localIdentifier).inserted {
                    discovered += 1
                }
                if let record = try await ledger.record(id: candidate.localIdentifier),
                   record.state == .queued || record.state == .uploaded {
                    continue
                }

                try await ledger.recordDiscovery(
                    id: candidate.localIdentifier,
                    createdAt: candidate.creationDate
                )
                let fileURL = uploadsDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("original")

                do {
                    try await photoSource.exportOriginal(
                        localIdentifier: candidate.localIdentifier,
                        to: fileURL
                    )
                    try await uploader.enqueue(
                        assetID: candidate.localIdentifier,
                        fileURL: fileURL
                    )
                    queued += 1
                } catch {
                    failed += 1
                    let category: UploadErrorCategory
                    if let configurationError = error as? UploadConfigurationError,
                       configurationError == .missingCredential
                        || configurationError == .authenticationBlocked {
                        category = .authentication
                    } else if error is URLError {
                        category = .network
                    } else {
                        category = .unreadable
                    }
                    try? await ledger.markFailed(
                        id: candidate.localIdentifier,
                        category: category
                    )
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }

        return SyncEnqueueSummary(
            discovered: discovered,
            queued: queued,
            failed: failed
        )
    }
}
