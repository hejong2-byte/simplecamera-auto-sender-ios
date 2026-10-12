import Foundation
import CryptoKit

enum ManualTransferRetryError: Error, LocalizedError, Equatable {
    case notFound
    case notFailed
    case alreadyRetrying
    case recipientChanged
    case documentReselectionRequired(fileName: String)
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .notFound: "전송 기록을 찾을 수 없습니다."
        case .notFailed: "실패한 전송만 다시 보낼 수 있습니다."
        case .alreadyRetrying: "이미 다시 보내기를 시작한 항목입니다."
        case .recipientChanged: "원래 수신처의 인증 정보가 변경되었습니다."
        case let .documentReselectionRequired(fileName): "다시 보낼 파일을 선택하세요: \(fileName)"
        case .sourceChanged: "선택한 파일이 원래 보낸 파일과 다릅니다."
        }
    }
}

enum ManualRecipientBinding {
    static func digest(_ credential: String?) -> String? {
        guard let value = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ManualTransferFailureCategory: String, Hashable, Sendable {
    case unavailable
    case unsupported
    case tooLarge
    case fileAccess
    case storage
    case authentication
    case network
    case server
    case other
}

struct ManualMediaTransferSummary: Sendable, Equatable {
    let selected: Int
    let uploaded: Int
    let failed: Int
    let failureCategories: Set<ManualTransferFailureCategory>

    static let empty = ManualMediaTransferSummary(
        selected: 0,
        uploaded: 0,
        failed: 0,
        failureCategories: []
    )
}

protocol ManualMediaTransferring: Sendable {
    func enqueue(
        selection: ManualMediaSelection,
        kind: ManualMediaKind
    ) async -> ManualMediaTransferSummary
    func updates() async -> AsyncStream<ManualTransferProgress>
}

actor ManualMediaTransferService: ManualMediaTransferring {
    private let source: ManualMediaSourcing
    private let jobStore: ManualTransferJobStore
    private let engine: ManualTransferQueueing
    private let exportDirectory: URL
    private let maxBytes: Int64
    private let singleRequestMaxBytes: Int64
    private let multipartPartBytes: Int?
    private let credentialStore: CredentialStore
    private var continuations: [UUID: AsyncStream<ManualTransferProgress>.Continuation] = [:]
    private var engineBridgeTask: Task<Void, Never>?

    init(
        source: ManualMediaSourcing,
        jobStore: ManualTransferJobStore,
        engine: ManualTransferQueueing,
        exportDirectory: URL,
        maxBytes: Int64 = ManualMediaUploadLimit.maxBytes,
        singleRequestMaxBytes: Int64 = ManualMediaUploadLimit.singleRequestMaxBytes,
        multipartPartBytes: Int? = nil,
        credentialStore: CredentialStore = KeychainCredentialStore()
    ) {
        self.source = source
        self.jobStore = jobStore
        self.engine = engine
        self.exportDirectory = exportDirectory
        self.maxBytes = maxBytes
        self.singleRequestMaxBytes = singleRequestMaxBytes
        self.multipartPartBytes = multipartPartBytes
        self.credentialStore = credentialStore
    }

    func history() async throws -> [ManualTransferHistoryEntry] {
        try await jobStore.load().history
    }

    func retryFailed(historyID: UUID, reselectedFileURL: URL? = nil) async throws -> ManualMediaTransferSummary {
        let entry = try await jobStore.claimRetry(id: historyID)
        do {
            if entry.recipientMailboxID == nil {
                guard let binding = entry.recipientCredentialBinding,
                      binding == ManualRecipientBinding.digest(try credentialStore.load()) else {
                    throw ManualTransferRetryError.recipientChanged
                }
            }
            if entry.kind == .file {
                guard let reselectedFileURL else {
                    throw ManualTransferRetryError.documentReselectionRequired(fileName: entry.fileName)
                }
                if entry.sha256 == nil, reselectedFileURL.lastPathComponent != entry.fileName {
                    throw ManualTransferRetryError.sourceChanged
                }
            }
            var validationError: ManualTransferRetryError?
            let summary = await enqueue(
                selection: .init(assetIdentifiers: [entry.assetIdentifier], unavailableCount: 0),
                kind: entry.kind,
                recipientMailboxID: entry.recipientMailboxID,
                fileNames: [entry.assetIdentifier: entry.fileName],
                recipientCredentialBinding: entry.recipientCredentialBinding,
                expectedSHA256: entry.kind == .file ? entry.sha256 : nil,
                retryHistoryID: entry.id,
                onPreparationFailure: { validationError = $0 as? ManualTransferRetryError }
            ) { [source, exportDirectory, maxBytes] identifier, onProgress in
                if entry.kind == .file, let reselectedFileURL {
                    return try await ManualDocumentSource(maxBytes: maxBytes).exportOriginal(
                        fileURL: reselectedFileURL, identifier: identifier,
                        to: exportDirectory, onProgress: onProgress
                    )
                }
                return try await source.exportOriginal(
                    assetIdentifier: identifier, kind: entry.kind, to: exportDirectory
                )
            }
            try await jobStore.finishRetry(id: historyID, enqueued: summary.failed == 0)
            if let validationError { throw validationError }
            return summary
        } catch {
            try? await jobStore.finishRetry(id: historyID, enqueued: false)
            throw error
        }
    }

    func updates() async -> AsyncStream<ManualTransferProgress> {
        let id = UUID()
        let pair = AsyncStream.makeStream(of: ManualTransferProgress.self)
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        if engineBridgeTask == nil {
            let engineUpdates = await engine.updates()
            engineBridgeTask = Task { [weak self] in
                for await progress in engineUpdates {
                    guard !Task.isCancelled else { break }
                    await self?.publish(progress)
                }
            }
        }
        return pair.stream
    }

    func enqueue(
        selection: ManualMediaSelection,
        kind: ManualMediaKind
    ) async -> ManualMediaTransferSummary {
        await enqueue(selection: selection, kind: kind) { [source, exportDirectory] identifier, _ in
            try await source.exportOriginal(assetIdentifier: identifier, kind: kind, to: exportDirectory)
        }
    }

    func enqueueFiles(
        _ urls: [URL],
        recipientCode: String? = nil
    ) async -> ManualMediaTransferSummary {
        var seen = Set<String>()
        let selected = urls.filter { seen.insert($0.standardizedFileURL.absoluteString).inserted }
        let recipientMailboxID: UUID?
        do {
            recipientMailboxID = try recipientCode.map(PCFileMailbox.identifier(for:))
        } catch {
            return ManualMediaTransferSummary(
                selected: selected.count,
                uploaded: 0,
                failed: selected.count,
                failureCategories: [.other]
            )
        }
        let identifiers = selected.map { _ in "document-\(UUID().uuidString)" }
        let files = Dictionary(uniqueKeysWithValues: zip(identifiers, selected))
        let source = ManualDocumentSource(maxBytes: maxBytes)
        return await enqueue(
            selection: ManualMediaSelection(assetIdentifiers: identifiers, unavailableCount: 0),
            kind: .file,
            recipientMailboxID: recipientMailboxID,
            fileNames: files.mapValues(\.lastPathComponent)
        ) { [exportDirectory] identifier, onProgress in
            guard let url = files[identifier] else { throw ManualDocumentSourceError.unavailable }
            return try await source.exportOriginal(
                fileURL: url,
                identifier: identifier,
                to: exportDirectory,
                onProgress: onProgress
            )
        }
    }

    private func enqueue(
        selection: ManualMediaSelection,
        kind: ManualMediaKind,
        recipientMailboxID: UUID? = nil,
        fileNames: [String: String] = [:],
        recipientCredentialBinding: String? = nil,
        expectedSHA256: String? = nil,
        retryHistoryID: UUID? = nil,
        onPreparationFailure: ((Error) -> Void)? = nil,
        export: (
            String,
            (Int64, Int64) -> Void
        ) async throws -> ManualMediaExport
    ) async -> ManualMediaTransferSummary {
        var seen = Set<String>()
        let identifiers = selection.assetIdentifiers.filter { seen.insert($0).inserted }
        let selectedCount = identifiers.count + selection.unavailableCount
        guard selectedCount > 0 else { return .empty }
        let binding = recipientMailboxID == nil
            ? recipientCredentialBinding ?? ManualRecipientBinding.digest(try? credentialStore.load())
            : nil

        let batchID = UUID()
        var batch = ManualTransferBatch(
            id: batchID,
            kind: kind,
            selectedCount: selectedCount,
            preparedCount: selection.unavailableCount,
            uploadedCount: 0,
            failedCount: selection.unavailableCount
        )
        var categories: Set<ManualTransferFailureCategory> = selection.unavailableCount > 0
            ? [.unavailable]
            : []
        do {
            try await jobStore.upsertBatch(batch)
        } catch {
            return ManualMediaTransferSummary(
                selected: selectedCount,
                uploaded: 0,
                failed: selectedCount,
                failureCategories: [.other]
            )
        }
        publish(preparationProgress(
            batch: batch,
            currentIndex: max(selection.unavailableCount, 1),
            stage: .preparing,
            failure: selection.unavailableCount > 0 ? .other : nil
        ))

        for (offset, identifier) in identifiers.enumerated() {
            let currentIndex = selection.unavailableCount + offset + 1
            var exportedFileURL: URL?
            var partURLs: [URL] = []
            var preparationRecorded = false
            var fileName = fileNames[identifier] ?? identifier
            var sha256: String?
            do {
                let exported = try await export(identifier) { processedBytes, totalBytes in
                    publish(preparationProgress(
                        batch: batch,
                        currentIndex: currentIndex,
                        stage: .preparing,
                        totalBytes: totalBytes,
                        processedBytes: processedBytes,
                        preparationPhase: kind == .file ? .copyingDocument : nil
                    ))
                }
                exportedFileURL = exported.fileURL
                fileName = exported.fileName
                let fingerprint = try UploadFileFingerprinter.fingerprint(
                    fileURL: exported.fileURL,
                    onProgress: { processedBytes, totalBytes in
                        publish(preparationProgress(
                            batch: batch,
                            currentIndex: currentIndex,
                            stage: .preparing,
                            totalBytes: totalBytes,
                            processedBytes: processedBytes,
                            preparationPhase: .fingerprinting
                        ))
                    }
                )
                sha256 = fingerprint.sha256
                if let expectedSHA256, expectedSHA256 != fingerprint.sha256 {
                    throw ManualTransferRetryError.sourceChanged
                }
                guard fingerprint.size <= maxBytes else {
                    throw ManualMediaUploadError.fileTooLarge(maxBytes: maxBytes)
                }

                let jobID = UUID()
                var parts: [ManualTransferPart] = []
                if recipientMailboxID != nil || fingerprint.size > singleRequestMaxBytes {
                    let partDirectory = exportDirectory.appendingPathComponent(
                        "Multipart-\(jobID.uuidString)",
                        isDirectory: true
                    )
                    let selectedPartBytes = multipartPartBytes
                        ?? ManualMediaUploadLimit.multipartPartBytes(for: fingerprint.size)
                    parts = try ManualMultipartFiles.planParts(
                        source: exported.fileURL,
                        directory: partDirectory,
                        partBytes: selectedPartBytes
                    )
                    partURLs = parts.map(\.fileURL)
                }

                batch = try await jobStore.advanceBatch(
                    id: batchID,
                    preparedBy: 1,
                    failedBy: 0
                )
                preparationRecorded = true
                let job = ManualTransferJob(
                    id: jobID,
                    batchID: batchID,
                    assetIdentifier: identifier,
                    kind: kind,
                    selectedCount: selectedCount,
                    currentIndex: currentIndex,
                    exportedFileURL: exported.fileURL,
                    originalFileName: exported.fileName,
                    contentType: exported.contentType,
                    capturedAt: exported.capturedAt,
                    sha256: fingerprint.sha256,
                    remoteID: fingerprint.remoteID,
                    recipientMailboxID: recipientMailboxID,
                    totalBytes: fingerprint.size,
                    stage: .preparing,
                    uploadID: nil,
                    parts: parts,
                    failure: nil,
                    recipientCredentialBinding: binding,
                    retryHistoryID: retryHistoryID
                )
                try await engine.enqueue([job])
                publish(preparationProgress(
                    batch: batch,
                    currentIndex: currentIndex,
                    stage: .preparing,
                    totalBytes: fingerprint.size
                ))
            } catch {
                onPreparationFailure?(error)
                batch = (try? await jobStore.advanceBatch(
                    id: batchID,
                    preparedBy: preparationRecorded ? 0 : 1,
                    failedBy: 1
                )) ?? batch
                let category = Self.failureCategory(for: error)
                categories.insert(category)
                if !(error is ManualTransferRetryError) {
                    try? await jobStore.recordHistory(.init(
                        id: UUID(), fileName: fileName, kind: kind,
                        recipientMailboxID: recipientMailboxID, completedAt: Date(),
                        failure: Self.progressFailure(for: error), assetIdentifier: identifier,
                        sha256: expectedSHA256 ?? sha256, recipientCredentialBinding: binding
                    ))
                }
                if let exportedFileURL {
                    try? FileManager.default.removeItem(at: exportedFileURL)
                }
                for partURL in partURLs {
                    try? FileManager.default.removeItem(at: partURL)
                }
                if let directory = partURLs.first?.deletingLastPathComponent() {
                    try? FileManager.default.removeItem(at: directory)
                }
                publish(preparationProgress(
                    batch: batch,
                    currentIndex: currentIndex,
                    stage: batch.failedCount == selectedCount ? .failed : .preparing,
                    failure: Self.progressFailure(for: error)
                ))
            }
        }

        return ManualMediaTransferSummary(
            selected: selectedCount,
            uploaded: 0,
            failed: batch.failedCount,
            failureCategories: categories
        )
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish(_ progress: ManualTransferProgress) {
        for continuation in continuations.values {
            continuation.yield(progress)
        }
    }

    private func preparationProgress(
        batch: ManualTransferBatch,
        currentIndex: Int,
        stage: ManualTransferStage,
        totalBytes: Int64 = 0,
        processedBytes: Int64 = 0,
        preparationPhase: ManualPreparationPhase? = nil,
        failure: ManualTransferFailure? = nil
    ) -> ManualTransferProgress {
        ManualTransferProgress(
            batchID: batch.id,
            kind: batch.kind,
            selectedCount: batch.selectedCount,
            currentIndex: min(max(currentIndex, 1), batch.selectedCount),
            uploadedCount: batch.uploadedCount,
            failedCount: batch.failedCount,
            stage: stage,
            totalBytes: totalBytes,
            confirmedBytes: 0,
            taskBytesSent: processedBytes,
            retryAttempt: 0,
            failure: failure,
            preparationPhase: preparationPhase
        )
    }

    private static func failureCategory(
        for error: Error
    ) -> ManualTransferFailureCategory {
        if let documentError = error as? ManualDocumentSourceError {
            switch documentError {
            case .storage: return .storage
            case .invalidFile: return .unsupported
            case .unavailable, .changed: return .fileAccess
            }
        }
        if let sourceError = error as? ManualMediaSourceError {
            switch sourceError {
            case .assetNotFound: return .unavailable
            case .kindMismatch, .originalResourceNotFound, .unsupportedContentType:
                return .unsupported
            }
        }
        if error is ManualMediaUploadError { return .tooLarge }
        if error is UploadConfigurationError { return .authentication }
        if error is URLError { return .network }
        if error is UploadHTTPError { return .server }
        return .other
    }

    private static func progressFailure(for error: Error) -> ManualTransferFailure {
        switch failureCategory(for: error) {
        case .unsupported, .unavailable: .unsupported
        case .tooLarge: .tooLarge
        case .fileAccess: .fileAccess
        case .storage: .storage
        case .authentication: .authentication
        case .network: .network
        case .server: .server(statusCode: 0, code: nil)
        case .other: .other
        }
    }
}
