import Foundation

protocol UploadCoordinating: Sendable {
    func enqueue(assetID: String, fileURL: URL) async throws
    func reconnect() async
    func authenticationBlocked() -> Bool
    func credentialDidChange()
}

final class BackgroundUploadCoordinator: NSObject, UploadCoordinating, @unchecked Sendable {
    private struct TaskContext: Codable {
        let assetID: String
        let filePath: String
    }

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
    private let requestFactory = RelayRequestFactory()
    private let lock = NSLock()
    private var authenticationBlockedValue = false
    private var backgroundEventsCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: AppConfiguration.backgroundSessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(ledger: UploadLedger, credentialStore: CredentialStore) {
        self.ledger = ledger
        self.credentialStore = credentialStore
        super.init()
    }

    func enqueue(assetID: String, fileURL: URL) async throws {
        guard !authenticationBlocked() else {
            throw UploadConfigurationError.authenticationBlocked
        }
        guard let credential = try credentialStore.load() else {
            throw UploadConfigurationError.missingCredential
        }

        let request = try requestFactory.makeUploadRequest(credential: credential)
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = try encodeContext(TaskContext(
            assetID: assetID,
            filePath: fileURL.path
        ))
        do {
            try await ledger.markQueued(id: assetID, taskIdentifier: task.taskIdentifier)
            task.resume()
        } catch {
            task.cancel()
            throw error
        }
    }

    func reconnect() async {
        let tasks = await allTasks()
        for task in tasks {
            guard let context = decodeContext(task.taskDescription) else { continue }
            try? await ledger.markQueued(
                id: context.assetID,
                taskIdentifier: task.taskIdentifier
            )
        }
    }

    func authenticationBlocked() -> Bool {
        lock.withLock { authenticationBlockedValue }
    }

    func credentialDidChange() {
        lock.withLock { authenticationBlockedValue = false }
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        lock.withLock {
            backgroundEventsCompletionHandler = completionHandler
        }
        _ = session
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func encodeContext(_ context: TaskContext) throws -> String {
        try JSONEncoder().encode(context).base64EncodedString()
    }

    private func decodeContext(_ value: String?) -> TaskContext? {
        guard let value,
              let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(TaskContext.self, from: data)
    }

    private func blockAuthentication(excluding completedTask: URLSessionTask) {
        let isFirstBlock = lock.withLock { () -> Bool in
            if authenticationBlockedValue { return false }
            authenticationBlockedValue = true
            return true
        }
        guard isFirstBlock else { return }

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where task.taskIdentifier != completedTask.taskIdentifier {
                guard task.countOfBytesSent == 0,
                      let context = self.decodeContext(task.taskDescription) else { continue }
                task.cancel()
                Task {
                    try? await self.ledger.markFailed(
                        id: context.assetID,
                        category: .authentication
                    )
                }
            }
        }
    }
}

extension BackgroundUploadCoordinator: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let context = decodeContext(task.taskDescription) else { return }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 || statusCode == 403 {
            blockAuthentication(excluding: task)
        }

        Task {
            if let error {
                let category: UploadErrorCategory
                if authenticationBlocked(), (error as? URLError)?.code == .cancelled {
                    category = .authentication
                } else if error is URLError {
                    category = .network
                } else {
                    category = .unknown
                }
                try? await ledger.markFailed(id: context.assetID, category: category)
                return
            }

            switch statusCode {
            case 200...299:
                try? await ledger.markUploaded(id: context.assetID)
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: context.filePath)
                )
            case 401, 403:
                try? await ledger.markFailed(id: context.assetID, category: .authentication)
            case 500...599:
                try? await ledger.markFailed(id: context.assetID, category: .server)
            default:
                try? await ledger.markFailed(id: context.assetID, category: .unknown)
            }
        }
    }
}

extension BackgroundUploadCoordinator: URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completionHandler = lock.withLock { () -> (() -> Void)? in
            defer { backgroundEventsCompletionHandler = nil }
            return backgroundEventsCompletionHandler
        }
        guard let completionHandler else { return }
        Task { @MainActor in
            completionHandler()
        }
    }
}
