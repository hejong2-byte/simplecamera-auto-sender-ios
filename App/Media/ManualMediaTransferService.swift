import Foundation

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
    private let multipartPartBytes: Int
    private var continuations: [UUID: AsyncStream<ManualTransferProgress>.Continuation] = [:]
    private var engineBridgeTask: Task<Void, Never>?

    init(
        source: ManualMediaSourcing,
        jobStore: ManualTransferJobStore,
        engine: ManualTransferQueueing,
        exportDirectory: URL,
        maxBytes: Int64 = ManualMediaUploadLimit.maxBytes,
        singleRequestMaxBytes: Int64 = ManualMediaUploadLimit.singleRequestMaxBytes,
        multipartPartBytes: Int = ManualMediaUploadLimit.multipartPartBytes
    ) {
        self.source = source
        self.jobStore = jobStore
        self.engine = engine
        self.exportDirectory = exportDirectory
        self.maxBytes = maxBytes
        self.singleRequestMaxBytes = singleRequestMaxBytes
        self.multipartPartBytes = multipartPartBytes
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
        await enqueue(selection: selection, kind: kind) { [source, exportDirectory] identifier in
            try await source.exportOriginal(assetIdentifier: identifier, kind: kind, to: exportDirectory)
        }
    }

    func enqueueFiles(_ urls: [URL]) async -> ManualMediaTransferSummary {
        var seen = Set<String>()
        let selected = urls.filter { seen.insert($0.standardizedFileURL.absoluteString).inserted }
        let identifiers = selected.map { _ in "document-\(UUID().uuidString)" }
        let files = Dictionary(uniqueKeysWithValues: zip(identifiers, selected))
        let source = ManualDocumentSource(maxBytes: maxBytes)
        return await enqueue(
            selection: ManualMediaSelection(assetIdentifiers: identifiers, unavailableCount: 0), kind: .file
        ) { [exportDirectory] identifier in
            guard let url = files[identifier] else { throw ManualDocumentSourceError.unavailable }
            return try await source.exportOriginal(fileURL: url, identifier: identifier, to: exportDirectory)
        }
    }

    private func enqueue(
        selection: ManualMediaSelection,
        kind: ManualMediaKind,
        export: @Sendable (String) async throws -> ManualMediaExport
    ) async -> ManualMediaTransferSummary {
        var seen = Set<String>()
        let identifiers = selection.assetIdentifiers.filter { seen.insert($0).inserted }
        let selectedCount = identifiers.count + selection.unavailableCount
        guard selectedCount > 0 else { return .empty }

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
            do {
                let exported = try await export(identifier)
                exportedFileURL = exported.fileURL
                let fingerprint = try UploadFileFingerprinter.fingerprint(
                    fileURL: exported.fileURL
                )
                guard fingerprint.size <= maxBytes else {
                    throw ManualMediaUploadError.fileTooLarge(maxBytes: maxBytes)
                }

                let jobID = UUID()
                var parts: [ManualTransferPart] = []
                if fingerprint.size > singleRequestMaxBytes {
                    let partDirectory = exportDirectory.appendingPathComponent(
                        "Multipart-\(jobID.uuidString)",
                        isDirectory: true
                    )
                    partURLs = try ManualMultipartFiles.makeParts(
                        source: exported.fileURL,
                        directory: partDirectory,
                        partBytes: multipartPartBytes
                    )
                    parts = try partURLs.enumerated().map { offset, url in
                        let values = try url.resourceValues(forKeys: [.fileSizeKey])
                        guard let size = values.fileSize else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        return ManualTransferPart(
                            number: offset + 1,
                            fileURL: url,
                            size: Int64(size),
                            etag: nil,
                            retryAttempt: 0
                        )
                    }
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
                    totalBytes: fingerprint.size,
                    stage: .preparing,
                    uploadID: nil,
                    parts: parts,
                    failure: nil
                )
                try await engine.enqueue([job])
                publish(preparationProgress(
                    batch: batch,
                    currentIndex: currentIndex,
                    stage: .preparing,
                    totalBytes: fingerprint.size
                ))
            } catch {
                batch = (try? await jobStore.advanceBatch(
                    id: batchID,
                    preparedBy: preparationRecorded ? 0 : 1,
                    failedBy: 1
                )) ?? batch
                let category = Self.failureCategory(for: error)
                categories.insert(category)
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
            taskBytesSent: 0,
            retryAttempt: 0,
            failure: failure
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
