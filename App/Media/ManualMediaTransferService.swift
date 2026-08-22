import Foundation

enum ManualTransferFailureCategory: String, Hashable, Sendable {
    case unavailable
    case unsupported
    case tooLarge
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
    func send(
        selection: ManualMediaSelection,
        kind: ManualMediaKind
    ) async -> ManualMediaTransferSummary
}

struct ManualMediaTransferService: ManualMediaTransferring {
    private let source: ManualMediaSourcing
    private let ledger: UploadLedger
    private let uploader: UploadCoordinating
    private let exportDirectory: URL

    init(
        source: ManualMediaSourcing,
        ledger: UploadLedger,
        uploader: UploadCoordinating,
        exportDirectory: URL
    ) {
        self.source = source
        self.ledger = ledger
        self.uploader = uploader
        self.exportDirectory = exportDirectory
    }

    func send(
        selection: ManualMediaSelection,
        kind: ManualMediaKind
    ) async -> ManualMediaTransferSummary {
        var seen = Set<String>()
        let identifiers = selection.assetIdentifiers.filter { seen.insert($0).inserted }
        var uploaded = 0
        var failed = selection.unavailableCount
        var categories: Set<ManualTransferFailureCategory> = selection.unavailableCount > 0
            ? [.unavailable]
            : []

        for identifier in identifiers {
            do {
                try await transfer(assetIdentifier: identifier, kind: kind)
                uploaded += 1
            } catch {
                failed += 1
                categories.insert(Self.failureCategory(for: error))
            }
        }

        return ManualMediaTransferSummary(
            selected: identifiers.count + selection.unavailableCount,
            uploaded: uploaded,
            failed: failed,
            failureCategories: categories
        )
    }

    private func transfer(
        assetIdentifier: String,
        kind: ManualMediaKind
    ) async throws {
        let exported = try await source.exportOriginal(
            assetIdentifier: assetIdentifier,
            kind: kind,
            to: exportDirectory
        )
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }

        try await ledger.recordDiscovery(
            id: assetIdentifier,
            createdAt: exported.capturedAt ?? Date()
        )
        do {
            try await uploader.upload(
                assetID: assetIdentifier,
                fileURL: exported.fileURL,
                metadata: ManualMediaUploadMetadata(
                    fileName: exported.fileName,
                    contentType: exported.contentType,
                    capturedAt: exported.capturedAt
                )
            )
        } catch {
            try? await ledger.markFailed(
                id: assetIdentifier,
                category: Self.uploadErrorCategory(for: error)
            )
            throw error
        }
    }

    private static func failureCategory(
        for error: Error
    ) -> ManualTransferFailureCategory {
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

    private static func uploadErrorCategory(for error: Error) -> UploadErrorCategory {
        switch failureCategory(for: error) {
        case .authentication: .authentication
        case .network: .network
        case .server: .server
        case .unavailable, .unsupported, .tooLarge, .other: .unreadable
        }
    }
}
