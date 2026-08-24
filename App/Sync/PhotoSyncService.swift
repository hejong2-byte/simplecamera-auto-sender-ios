import Foundation

enum SyncTrigger: Sendable {
    case automation
    case manual
    case retry
}

struct SyncTransferSummary: Sendable, Equatable {
    let discovered: Int
    let matched: Int
    let uploaded: Int
    let failed: Int
    let failureCategories: Set<UploadErrorCategory>

    init(
        discovered: Int,
        matched: Int,
        uploaded: Int,
        failed: Int,
        failureCategories: Set<UploadErrorCategory> = []
    ) {
        self.discovered = discovered
        self.matched = matched
        self.uploaded = uploaded
        self.failed = failed
        self.failureCategories = failureCategories
    }

    var failureDescription: String? {
        failureCategories.uploadFailureDescription
    }

    var automationResultDescription: String {
        if failed > 0 {
            let reason = failureDescription.map { " (\($0))" } ?? ""
            return "\(uploaded)장 완료, \(failed)장 재시도 대기\(reason)"
        }
        return "\(uploaded)장 전송 완료"
    }
}

enum PhotoSyncError: Error {
    case monitoringNotEnabled
}

private struct CandidateTransferOutcome: Sendable {
    let candidateID: String
    let matched: Int
    let uploaded: Int
    let failed: Int
    let failureCategory: UploadErrorCategory?
}

actor PhotoSyncService {
    private let credentialStore: CredentialStore
    private let photoSource: PhotoAssetSourcing
    private let metadataMatcher: SimpleCameraMetadataMatching
    private let ledger: UploadLedger
    private let uploader: UploadCoordinating
    private let uploadsDirectory: URL
    private let scanDelaysNanoseconds: [UInt64]
    private var inFlight: Task<SyncTransferSummary, Error>?

    init(
        credentialStore: CredentialStore,
        photoSource: PhotoAssetSourcing,
        metadataMatcher: SimpleCameraMetadataMatching,
        ledger: UploadLedger,
        uploader: UploadCoordinating,
        uploadsDirectory: URL,
        scanDelaysNanoseconds: [UInt64] = [0]
            + Array(repeating: 500_000_000, count: 20)
    ) {
        self.credentialStore = credentialStore
        self.photoSource = photoSource
        self.metadataMatcher = metadataMatcher
        self.ledger = ledger
        self.uploader = uploader
        self.uploadsDirectory = uploadsDirectory
        self.scanDelaysNanoseconds = scanDelaysNanoseconds
    }

    func run(trigger: SyncTrigger) async throws -> SyncTransferSummary {
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

    private func performRun(trigger: SyncTrigger) async throws -> SyncTransferSummary {
        guard let credential = try credentialStore.load(),
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UploadConfigurationError.missingCredential
        }
        guard let baseline = try await ledger.baseline() else {
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
        var matchedIDs = Set<String>()
        var uploadedIDs = Set<String>()
        var failuresByID: [String: UploadErrorCategory] = [:]
        var completedUploadInEarlierScan = false

        for (scanIndex, delay) in scanDelaysNanoseconds.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            let candidates = try await photoSource.candidates(
                createdAfter: baseline.addingTimeInterval(-60)
            )
            var candidatesToTransfer: [PhotoCandidate] = []

            for candidate in candidates {
                if discoveredIDs.insert(candidate.localIdentifier).inserted {
                    discovered += 1
                }
                if let record = try await ledger.record(id: candidate.localIdentifier),
                   record.state == .queued || record.state == .uploaded || record.state == .ignored {
                    continue
                }

                try await ledger.recordDiscovery(
                    id: candidate.localIdentifier,
                    createdAt: candidate.creationDate
                )
                candidatesToTransfer.append(candidate)
            }

            let outcomes = await transfer(
                candidates: candidatesToTransfer,
                isFinalScan: scanIndex == scanDelaysNanoseconds.indices.last
            )
            let completedUploadsThisScan = outcomes.reduce(0) { $0 + $1.uploaded }
            for outcome in outcomes {
                if outcome.matched > 0 { _ = matchedIDs.insert(outcome.candidateID) }
                if outcome.uploaded > 0 {
                    _ = uploadedIDs.insert(outcome.candidateID)
                    failuresByID.removeValue(forKey: outcome.candidateID)
                }
                if outcome.failed > 0,
                   !uploadedIDs.contains(outcome.candidateID),
                   let category = outcome.failureCategory {
                    failuresByID[outcome.candidateID] = category
                }
            }

            if completedUploadInEarlierScan && completedUploadsThisScan == 0 {
                break
            }
            if completedUploadsThisScan > 0 {
                completedUploadInEarlierScan = true
            }
        }

        return SyncTransferSummary(
            discovered: discovered,
            matched: matchedIDs.count,
            uploaded: uploadedIDs.count,
            failed: failuresByID.count,
            failureCategories: Set(failuresByID.values)
        )
    }

    private func transfer(
        candidates: [PhotoCandidate],
        isFinalScan: Bool
    ) async -> [CandidateTransferOutcome] {
        let photoSource = self.photoSource
        let metadataMatcher = self.metadataMatcher
        let ledger = self.ledger
        let uploader = self.uploader
        let uploadsDirectory = self.uploadsDirectory
        return await withTaskGroup(
            of: CandidateTransferOutcome.self,
            returning: [CandidateTransferOutcome].self
        ) { group in
            for candidate in candidates {
                group.addTask {
                    await Self.transfer(
                        candidate: candidate,
                        isFinalScan: isFinalScan,
                        photoSource: photoSource,
                        metadataMatcher: metadataMatcher,
                        ledger: ledger,
                        uploader: uploader,
                        uploadsDirectory: uploadsDirectory
                    )
                }
            }

            var outcomes: [CandidateTransferOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    private static func transfer(
        candidate: PhotoCandidate,
        isFinalScan: Bool,
        photoSource: PhotoAssetSourcing,
        metadataMatcher: SimpleCameraMetadataMatching,
        ledger: UploadLedger,
        uploader: UploadCoordinating,
        uploadsDirectory: URL
    ) async -> CandidateTransferOutcome {
        let fileURL = uploadsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("original")
        var didMatch = false

        do {
            try await photoSource.exportOriginal(
                localIdentifier: candidate.localIdentifier,
                to: fileURL
            )
            didMatch = metadataMatcher.matches(fileURL: fileURL)
            guard didMatch else {
                if isFinalScan {
                    try await ledger.markIgnored(id: candidate.localIdentifier)
                }
                try? FileManager.default.removeItem(at: fileURL)
                return CandidateTransferOutcome(
                    candidateID: candidate.localIdentifier,
                    matched: 0,
                    uploaded: 0,
                    failed: 0,
                    failureCategory: nil
                )
            }

            try await uploader.upload(
                assetID: candidate.localIdentifier,
                fileURL: fileURL
            )
            return CandidateTransferOutcome(
                candidateID: candidate.localIdentifier,
                matched: 1,
                uploaded: 1,
                failed: 0,
                failureCategory: nil
            )
        } catch {
            let category = errorCategory(for: error)
            try? await ledger.markFailed(
                id: candidate.localIdentifier,
                category: category
            )
            try? FileManager.default.removeItem(at: fileURL)
            return CandidateTransferOutcome(
                candidateID: candidate.localIdentifier,
                matched: didMatch ? 1 : 0,
                uploaded: 0,
                failed: 1,
                failureCategory: category
            )
        }
    }

    private static func errorCategory(for error: Error) -> UploadErrorCategory {
        if let configurationError = error as? UploadConfigurationError,
           configurationError == .missingCredential
            || configurationError == .authenticationBlocked {
            return .authentication
        }
        if error is URLError {
            return .network
        }
        if let uploadError = error as? UploadHTTPError {
            switch uploadError {
            case .server:
                return .server
            case .invalidResponse:
                return .unknown
            }
        }
        return .unreadable
    }
}
