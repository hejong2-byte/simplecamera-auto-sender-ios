import Foundation

protocol UploadCoordinating: Sendable {
    func upload(assetID: String, fileURL: URL) async throws
    func authenticationBlocked() -> Bool
    func credentialDidChange()
}

protocol HTTPFileUploading: Sendable {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse)
}

enum UploadHTTPError: Error, Equatable {
    case invalidResponse
    case server(statusCode: Int)
}

private struct URLSessionFileUploader: HTTPFileUploading, @unchecked Sendable {
    let session: URLSession

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL)
    }
}

final class BackgroundUploadCoordinator: UploadCoordinating, @unchecked Sendable {
    static let shared: BackgroundUploadCoordinator = {
        do {
            let ledger = try UploadLedger(fileURL: UploadLedger.defaultFileURL())
            return BackgroundUploadCoordinator(
                ledger: ledger,
                credentialStore: KeychainCredentialStore()
            )
        } catch {
            fatalError("업로드 장부를 열 수 없습니다.")
        }
    }()

    let ledger: UploadLedger
    private let credentialStore: CredentialStore
    private let transport: HTTPFileUploading
    private let requestFactory = RelayRequestFactory()
    private let lock = NSLock()
    private var authenticationBlockedValue = false

    init(
        ledger: UploadLedger,
        credentialStore: CredentialStore,
        transport: HTTPFileUploading? = nil
    ) {
        self.ledger = ledger
        self.credentialStore = credentialStore
        self.transport = transport ?? Self.makeTransport()
    }

    func upload(assetID: String, fileURL: URL) async throws {
        guard !authenticationBlocked() else {
            throw UploadConfigurationError.authenticationBlocked
        }
        guard let credential = try credentialStore.load() else {
            throw UploadConfigurationError.missingCredential
        }

        try await ledger.markQueued(id: assetID, taskIdentifier: nil)
        let request = try requestFactory.makeUploadRequest(credential: credential)
        let (_, response) = try await transport.upload(
            for: request,
            fromFile: fileURL
        )
        guard let response = response as? HTTPURLResponse else {
            throw UploadHTTPError.invalidResponse
        }

        switch response.statusCode {
        case 200...299:
            try await ledger.markUploaded(id: assetID)
            try FileManager.default.removeItem(at: fileURL)
        case 401, 403:
            lock.withLock { authenticationBlockedValue = true }
            throw UploadConfigurationError.authenticationBlocked
        default:
            throw UploadHTTPError.server(statusCode: response.statusCode)
        }
    }

    func authenticationBlocked() -> Bool {
        lock.withLock { authenticationBlockedValue }
    }

    func credentialDidChange() {
        lock.withLock { authenticationBlockedValue = false }
    }

    private static func makeTransport() -> HTTPFileUploading {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSessionFileUploader(
            session: URLSession(configuration: configuration)
        )
    }
}
