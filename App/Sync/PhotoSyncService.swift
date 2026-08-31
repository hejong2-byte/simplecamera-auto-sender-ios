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
        if uploaded == 0 {
            return "전송할 새 Simple Cam 사진이 없습니다."
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
    private var libraryScanRequested = false

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
        switch trigger {
        case .automation, .manual:
            libraryScanRequested = true
        case .retry:
            break
        }
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { [self] in
            defer {
                inFlight = nil
                libraryScanRequested = false
            }
            return try await performRun()
        }
        inFlight = task
        return try await task.value
    }

    private func performRun() async throws -> SyncTransferSummary {
        let progressReporter = AutomaticTransferProgressReporter(
            store: automaticProgressStore
        )
        progressReporter.beginScanning()
        do {
            return try await performValidatedRun(
                progressReporter: progressReporter
            )
        } catch {
            progressReporter.interrupt(
                category: Self.isCancellation(error) ? nil : Self.errorCategory(for: error)
            )
            throw error
        }
    }

    private func performValidatedRun(
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
        var hasScannedLibrary = false
        var scanIndex = 0

        while scanIndex < scanDelaysNanoseconds.count
            || (libraryScanRequested && !hasScannedLibrary) {
            let delay = scanIndex < scanDelaysNanoseconds.count
                ? scanDelaysNanoseconds[scanIndex] : 0
            scanIndex += 1
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            progressReporter.beginScanning()
            let candidates: [PhotoCandidate]
            if libraryScanRequested {
                candidates = try await photoSource.candidates(
                    createdAfter: baseline.addingTimeInterval(-60)
                )
                hasScannedLibrary = true
            } else {
                candidates = try await ledger.retryableRecords().map {
                    PhotoCandidate(localIdentifier: $0.id, creationDate: $0.createdAt)
                }
            }
            var candidatesToTransfer: [PhotoCandidate] = []

            for candidate in candidates {
                if discoveredIDs.insert(candidate.localIdentifier).inserted {
                    discovered += 1
                }
                if uploadedIDs.contains(candidate.localIdentifier) { continue }
                if let record = try await ledger.record(id: candidate.localIdentifier),
                   record.state == .uploaded || record.state == .ignored {
                    continue
                }

                try await ledger.recordDiscovery(
                    id: candidate.localIdentifier,
                    createdAt: candidate.creationDate
                )
                candidatesToTransfer.append(candidate)
            }

            let outcomes = try await transfer(
                candidates: candidatesToTransfer,
                progressReporter: progressReporter
            )
            let completedUploadsThisScan = outcomes.reduce(0) { $0 + $1.uploaded }
            for outcome in outcomes {
                if outcome.matched == 0 && outcome.failed == 0 {
                    failuresByID.removeValue(forKey: outcome.candidateID)
                    matchedIDs.remove(outcome.candidateID)
                }
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

            if completedUploadInEarlierScan && completedUploadsThisScan == 0
                && failuresByID.isEmpty
                && !(libraryScanRequested && !hasScannedLibrary) {
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
        progressReporter: AutomaticTransferProgressReporter
    ) async throws -> [CandidateTransferOutcome] {
        let orderedCandidates = candidates.sorted { left, right in
            if left.creationDate == right.creationDate {
                return left.localIdentifier < right.localIdentifier
            }
            return left.creationDate < right.creationDate
        }
        var prepared: [PreparedCandidate] = []
        var outcomes: [CandidateTransferOutcome] = []
        defer {
            for item in prepared {
                try? FileManager.default.removeItem(at: item.fileURL)
            }
        }

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
                guard try metadataMatcher.matches(fileURL: fileURL) else {
                    try await ledger.markIgnored(id: candidate.localIdentifier)
                    progressReporter.discardUnmatchedFile(id: candidate.localIdentifier)
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
                progressReporter.registerPreparedFile(
                    id: candidate.localIdentifier,
                    bytes: fileBytes
                )
            } catch {
                if Self.isCancellation(error) {
                    try? FileManager.default.removeItem(at: fileURL)
                    throw error
                }
                let category = Self.errorCategory(for: error)
                try? await ledger.markFailed(
                    id: candidate.localIdentifier,
                    category: category
                )
                try? FileManager.default.removeItem(at: fileURL)
                progressReporter.finishCurrentFileFailed(
                    id: candidate.localIdentifier,
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
                id: item.candidate.localIdentifier,
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
                progressReporter.finishCurrentFileUploaded(
                    id: item.candidate.localIdentifier,
                    bytes: item.fileBytes
                )
                outcomes.append(CandidateTransferOutcome(
                    candidateID: item.candidate.localIdentifier,
                    matched: 1,
                    uploaded: 1,
                    failed: 0,
                    failureCategory: nil
                ))
            } catch {
                if Self.isCancellation(error) { throw error }
                let category = Self.errorCategory(for: error)
                try? await ledger.markFailed(
                    id: item.candidate.localIdentifier,
                    category: category
                )
                try? FileManager.default.removeItem(at: item.fileURL)
                progressReporter.finishCurrentFileFailed(
                    id: item.candidate.localIdentifier,
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

    private static func isCancellation(_ error: Error) -> Bool {
        let value = error as NSError
        return error is CancellationError
            || (value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled)
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
