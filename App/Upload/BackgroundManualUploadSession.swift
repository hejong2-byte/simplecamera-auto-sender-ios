import Foundation

enum ManualUploadOperation: Codable, Sendable, Equatable, Hashable {
    case single
    case start
    case part(number: Int)
    case complete
    case abort
}

struct ManualUploadTaskDescriptor: Codable, Sendable, Equatable, Hashable {
    let batchID: UUID
    let jobID: UUID
    let operation: ManualUploadOperation
}

extension ManualUploadTaskDescriptor {
    func encodedTaskDescription() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let description = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return description
    }

    init(taskDescription: String) throws {
        self = try JSONDecoder().decode(
            ManualUploadTaskDescriptor.self,
            from: Data(taskDescription.utf8)
        )
    }
}

protocol ManualUploadTaskScheduling: Sendable {
    func schedule(
        _ descriptor: ManualUploadTaskDescriptor,
        request: URLRequest,
        fileURL: URL
    ) async throws
    func existingDescriptors() async -> Set<ManualUploadTaskDescriptor>
    func cancel(jobID: UUID) async
}

final class BackgroundSessionCompletionRegistry: @unchecked Sendable {
    static let shared = BackgroundSessionCompletionRegistry()

    private let lock = NSLock()
    private var handlers: [String: () -> Void] = [:]

    func store(identifier: String, handler: @escaping () -> Void) {
        lock.withLock { handlers[identifier] = handler }
    }

    func finish(identifier: String) {
        let current = lock.withLock { () -> (() -> Void)? in
            handlers.removeValue(forKey: identifier)
        }
        current?()
    }
}

final class BackgroundManualUploadSession: NSObject, ManualUploadTaskScheduling, @unchecked Sendable {
    private let completionRegistry: BackgroundSessionCompletionRegistry
    private let lock = NSLock()
    private weak var engine: ManualBackgroundTransferEngine?
    private var responseBodies: [Int: Data] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: AppConfiguration.manualBackgroundSessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    init(completionRegistry: BackgroundSessionCompletionRegistry) {
        self.completionRegistry = completionRegistry
        super.init()
        _ = session
    }

    func bind(engine: ManualBackgroundTransferEngine) {
        lock.withLock { self.engine = engine }
    }

    func schedule(
        _ descriptor: ManualUploadTaskDescriptor,
        request: URLRequest,
        fileURL: URL
    ) async throws {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = try descriptor.encodedTaskDescription()
        task.resume()
    }

    func existingDescriptors() async -> Set<ManualUploadTaskDescriptor> {
        let tasks = await allTasks()
        return Set(tasks.compactMap(Self.descriptor(for:)))
    }

    func cancel(jobID: UUID) async {
        for task in await allTasks() {
            guard Self.descriptor(for: task)?.jobID == jobID else { continue }
            task.cancel()
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private static func descriptor(for task: URLSessionTask) -> ManualUploadTaskDescriptor? {
        guard let description = task.taskDescription else { return nil }
        return try? ManualUploadTaskDescriptor(taskDescription: description)
    }
}

extension BackgroundManualUploadSession: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.withLock {
            responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let descriptor = Self.descriptor(for: task) else { return }
        let currentEngine = lock.withLock { engine }
        Task {
            await currentEngine?.taskProgress(
                descriptor,
                sent: totalBytesSent,
                expected: totalBytesExpectedToSend
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let descriptor = Self.descriptor(for: task) else { return }
        let (currentEngine, body) = lock.withLock { () -> (ManualBackgroundTransferEngine?, Data) in
            let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
            return (engine, body)
        }
        Task {
            await currentEngine?.taskCompleted(
                descriptor,
                response: task.response as? HTTPURLResponse,
                body: body,
                error: error
            )
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [completionRegistry] in
            completionRegistry.finish(
                identifier: AppConfiguration.manualBackgroundSessionIdentifier
            )
        }
    }
}
