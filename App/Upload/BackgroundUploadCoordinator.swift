import Foundation

protocol UploadCoordinating: Sendable {
    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws
    func authenticationBlocked() -> Bool
    func credentialDidChange()
}

extension UploadCoordinating {
    func upload(
        assetID: String,
        fileURL: URL
    ) async throws {
        try await upload(
            assetID: assetID,
            fileURL: fileURL,
            onProgress: { _, _ in }
        )
    }
}

protocol HTTPFileUploading: Sendable {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (Data, URLResponse)
}

enum UploadHTTPError: Error, Equatable {
    case invalidResponse
    case server(statusCode: Int)
}

enum ManualMediaUploadError: Error, Equatable {
    case fileTooLarge(maxBytes: Int64)
}

enum ManualMediaUploadLimit {
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let singleRequestMaxBytes: Int64 = 95 * 1024 * 1024
    static let multipartPartBytes = 32 * 1024 * 1024
}

private final class URLSessionFileUploader: NSObject,
    HTTPFileUploading,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private struct TaskState {
        var responseData = Data()
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        let onProgress: @Sendable (Int64, Int64) -> Void
    }

    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private lazy var session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
    )

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        super.init()
    }

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            lock.withLock {
                states[task.taskIdentifier] = TaskState(
                    continuation: continuation,
                    onProgress: onProgress
                )
            }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let handler = lock.withLock {
            states[task.taskIdentifier]?.onProgress
        }
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.withLock {
            states[dataTask.taskIdentifier]?.responseData.append(data)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let state = lock.withLock {
            states.removeValue(forKey: task.taskIdentifier)
        }
        guard let state else { return }
        if let error {
            state.continuation.resume(throwing: error)
            return
        }
        guard let response = task.response else {
            state.continuation.resume(throwing: UploadHTTPError.invalidResponse)
            return
        }
        state.continuation.resume(returning: (state.responseData, response))
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

    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard !authenticationBlocked() else {
            throw UploadConfigurationError.authenticationBlocked
        }
        guard let credential = try credentialStore.load() else {
            throw UploadConfigurationError.missingCredential
        }

        let request = try requestFactory.makeUploadRequest(credential: credential)
        try await performUpload(
            assetID: assetID,
            fileURL: fileURL,
            request: request,
            onProgress: onProgress
        )
    }

    private func performUpload(
        assetID: String,
        fileURL: URL,
        request: URLRequest,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await ledger.markQueued(id: assetID, taskIdentifier: nil)
        let (_, response) = try await transport.upload(
            for: request,
            fromFile: fileURL,
            onProgress: onProgress
        )
        try validate(response: response)
        try await ledger.markUploaded(id: assetID)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func validate(response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw UploadHTTPError.invalidResponse
        }
        switch response.statusCode {
        case 200...299:
            return
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
        return URLSessionFileUploader(configuration: configuration)
    }
}
