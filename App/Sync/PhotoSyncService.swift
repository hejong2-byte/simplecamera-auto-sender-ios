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

private struct PreparedCandidate: Sendable {
    let candidate: PhotoCandidate
    let fileURL: URL
    let fileBytes: Int64
}

actor PhotoSyncService {
    private let credentialStore: CredentialStore
    private let photoSource: PhotoAssetSourcing
    private let metadataMatcher: SimpleCameraMetadataMatching
    private let ledger: UploadLedger
    private let uploader: UploadCoordinating
    private let uploadsDirectory: URL
    private let scanDelaysNanoseconds: [UInt64]
    private let automaticProgressStore: AutomaticTransferProgressStore
    private var inFlight: Task<SyncTransferSummary, Error>?

    init(
        credentialStore: CredentialStore,
        photoSource: PhotoAssetSourcing,
        metadataMatcher: SimpleCameraMetadataMatching,
        ledger: UploadLedger,
        uploader: UploadCoordinating,
        uploadsDirectory: URL,
        scanDelaysNanoseconds: [UInt64] = [0]
            + Array(repeating: 500_000_000, count: 20),
        automaticProgressStore: AutomaticTransferProgressStore = AutomaticTransferProgressStore()
    ) {
        self.credentialStore = credentialStore
        self.photoSource = photoSource
        self.metadataMatcher = metadataMatcher
        self.ledger = ledger
        self.uploader = uploader
        self.uploadsDirectory = uploadsDirectory
        self.scanDelaysNanoseconds = scanDelaysNanoseconds
        self.automaticProgressStore = automaticProgressStore
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
        let progressReporter = AutomaticTransferProgressReporter(
            store: automaticProgressStore
        )
        progressReporter.beginScanning()
        do {
            return try await performValidatedRun(
                trigger: trigger,
                progressReporter: progressReporter
            )
        } catch {
            progressReporter.finishRun(
                uploadedCount: 0,
                failedCount: 1,
                failureCategories: [Self.errorCategory(for: error)]
            )
            throw error
        }
    }

    private func performValidatedRun(
        trigger: SyncTrigger,
        progressReporter: AutomaticTransferProgressReporter
    ) async throws -> SyncTransferSummary {
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
            progressReporter.beginScanning()
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
                isFinalScan: scanIndex == scanDelaysNanoseconds.indices.last,
                progressReporter: progressReporter
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

        let summary = SyncTransferSummary(
            discovered: discovered,
            matched: matchedIDs.count,
            uploaded: uploadedIDs.count,
            failed: failuresByID.count,
            failureCategories: Set(failuresByID.values)
        )
        progressReporter.finishRun(
            uploadedCount: summary.uploaded,
            failedCount: summary.failed,
            failureCategories: summary.failureCategories
        )
        return summary
    }

    private func transfer(
        candidates: [PhotoCandidate],
        isFinalScan: Bool,
        progressReporter: AutomaticTransferProgressReporter
    ) async -> [CandidateTransferOutcome] {
        let orderedCandidates = candidates.sorted { left, right in
            if left.creationDate == right.creationDate {
                return left.localIdentifier < right.localIdentifier
            }
            return left.creationDate < right.creationDate
        }
        var prepared: [PreparedCandidate] = []
        var outcomes: [CandidateTransferOutcome] = []

        for (offset, candidate) in orderedCandidates.enumerated() {
            progressReporter.beginPreparing(
                currentIndex: offset + 1,
                knownCount: orderedCandidates.count
            )
            let fileURL = uploadsDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("original")

            do {
                try await photoSource.exportOriginal(
                    localIdentifier: candidate.localIdentifier,
                    to: fileURL
                )
                guard metadataMatcher.matches(fileURL: fileURL) else {
                    if isFinalScan {
                        try await ledger.markIgnored(id: candidate.localIdentifier)
                    }
                    try? FileManager.default.removeItem(at: fileURL)
                    outcomes.append(CandidateTransferOutcome(
                        candidateID: candidate.localIdentifier,
                        matched: 0,
                        uploaded: 0,
                        failed: 0,
                        failureCategory: nil
                    ))
                    continue
                }

                let fileBytes = Int64(
                    try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                )
                prepared.append(PreparedCandidate(
                    candidate: candidate,
                    fileURL: fileURL,
                    fileBytes: fileBytes
                ))
                progressReporter.registerPreparedFile(bytes: fileBytes)
            } catch {
                let category = Self.errorCategory(for: error)
                try? await ledger.markFailed(
                    id: candidate.localIdentifier,
                    category: category
                )
                try? FileManager.default.removeItem(at: fileURL)
                progressReporter.finishCurrentFileFailed(
                    category: category,
                    bytes: 0
                )
                outcomes.append(CandidateTransferOutcome(
                    candidateID: candidate.localIdentifier,
                    matched: 0,
                    uploaded: 0,
                    failed: 1,
                    failureCategory: category
                ))
            }
        }

        for (offset, item) in prepared.enumerated() {
            progressReporter.beginUpload(
                currentIndex: offset + 1,
                fileBytes: item.fileBytes
            )
            do {
                try await uploader.upload(
                    assetID: item.candidate.localIdentifier,
                    fileURL: item.fileURL
                ) { sent, total in
                    progressReporter.reportUpload(sent: sent, total: total)
                    if total > 0 && sent >= total {
                        progressReporter.markVerifying()
                    }
                }
                try? FileManager.default.removeItem(at: item.fileURL)
                progressReporter.finishCurrentFileUploaded(bytes: item.fileBytes)
                outcomes.append(CandidateTransferOutcome(
                    candidateID: item.candidate.localIdentifier,
                    matched: 1,
                    uploaded: 1,
                    failed: 0,
                    failureCategory: nil
                ))
            } catch {
                let category = Self.errorCategory(for: error)
                try? await ledger.markFailed(
                    id: item.candidate.localIdentifier,
                    category: category
                )
                try? FileManager.default.removeItem(at: item.fileURL)
                progressReporter.finishCurrentFileFailed(
                    category: category,
                    bytes: item.fileBytes
                )
                outcomes.append(CandidateTransferOutcome(
                    candidateID: item.candidate.localIdentifier,
                    matched: 1,
                    uploaded: 0,
                    failed: 1,
                    failureCategory: category
                ))
            }
        }

        return outcomes
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
