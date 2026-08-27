import Foundation

struct IPhoneReceiveTaskDescriptor: Codable, Sendable, Equatable, Hashable {
    let deliveryID: UUID

    func encodedTaskDescription() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let description = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return description
    }

    init(deliveryID: UUID) {
        self.deliveryID = deliveryID
    }

    init(taskDescription: String) throws {
        self = try JSONDecoder().decode(
            IPhoneReceiveTaskDescriptor.self,
            from: Data(taskDescription.utf8)
        )
    }
}

protocol IPhoneReceiveTaskScheduling: Sendable {
    func schedule(deliveryID: UUID, request: URLRequest) async throws
    func existingDeliveryIDs() async -> Set<UUID>
    func cancel(deliveryID: UUID) async
}

protocol IPhoneReceiveDownloadSink: AnyObject, Sendable {
    func downloadProgress(deliveryID: UUID, received: Int64, expected: Int64) async
    func downloadFinished(deliveryID: UUID, stagingURL: URL) async
    func downloadFailed(deliveryID: UUID, error: Error) async
}

enum BackgroundIPhoneReceiveError: Error, Equatable {
    case invalidTaskDescription
    case invalidResponse
    case stagingFileExists
}

final class BackgroundIPhoneReceiveSession: NSObject,
    IPhoneReceiveTaskScheduling,
    @unchecked Sendable {
    static let shared: BackgroundIPhoneReceiveSession = {
        let root = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try! BackgroundIPhoneReceiveSession(
            stagingDirectory: root
                .appendingPathComponent("SimpleCameraAutoSender", isDirectory: true)
                .appendingPathComponent("PCFileReceiver", isDirectory: true)
                .appendingPathComponent("ReceiveStaging", isDirectory: true),
            completionRegistry: .shared
        )
    }()

    private let stagingDirectory: URL
    private let completionRegistry: BackgroundSessionCompletionRegistry
    private let fileManager: FileManager
    private let lock = NSLock()
    private weak var sink: (any IPhoneReceiveDownloadSink)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: AppConfiguration.receiverBackgroundSessionIdentifier
        )
        configuration.waitsForConnectivity = true
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    init(
        stagingDirectory: URL,
        completionRegistry: BackgroundSessionCompletionRegistry,
        fileManager: FileManager = .default
    ) throws {
        self.stagingDirectory = stagingDirectory
        self.completionRegistry = completionRegistry
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        var staging = stagingDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try staging.setResourceValues(values)
        super.init()
        _ = session
    }

    func bind(sink: any IPhoneReceiveDownloadSink) {
        lock.withLock { self.sink = sink }
    }

    func schedule(deliveryID: UUID, request: URLRequest) async throws {
        let descriptor = IPhoneReceiveTaskDescriptor(deliveryID: deliveryID)
        let task = session.downloadTask(with: request)
        task.taskDescription = try descriptor.encodedTaskDescription()
        task.resume()
    }

    func existingDeliveryIDs() async -> Set<UUID> {
        Set((await allTasks()).compactMap(Self.descriptor(for:)).map(\.deliveryID))
    }

    func cancel(deliveryID: UUID) async {
        for task in await allTasks() where Self.descriptor(for: task)?.deliveryID == deliveryID {
            task.cancel()
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private static func descriptor(for task: URLSessionTask) -> IPhoneReceiveTaskDescriptor? {
        guard let description = task.taskDescription else { return nil }
        return try? IPhoneReceiveTaskDescriptor(taskDescription: description)
    }

    private func currentSink() -> (any IPhoneReceiveDownloadSink)? {
        lock.withLock { sink }
    }
}

extension BackgroundIPhoneReceiveSession: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let descriptor = Self.descriptor(for: downloadTask) else { return }
        let sink = currentSink()
        Task {
            await sink?.downloadProgress(
                deliveryID: descriptor.deliveryID,
                received: totalBytesWritten,
                expected: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let descriptor = Self.descriptor(for: downloadTask) else { return }
        let sink = currentSink()
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw BackgroundIPhoneReceiveError.invalidResponse
            }
            let destination = stagingDirectory.appendingPathComponent(
                descriptor.deliveryID.uuidString.lowercased() + ".download"
            )
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw BackgroundIPhoneReceiveError.stagingFileExists
            }
            try fileManager.moveItem(at: location, to: destination)
            Task {
                await sink?.downloadFinished(
                    deliveryID: descriptor.deliveryID,
                    stagingURL: destination
                )
            }
        } catch {
            Task {
                await sink?.downloadFailed(
                    deliveryID: descriptor.deliveryID,
                    error: error
                )
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let descriptor = Self.descriptor(for: task) else { return }
        let sink = currentSink()
        Task {
            await sink?.downloadFailed(deliveryID: descriptor.deliveryID, error: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [completionRegistry] in
            completionRegistry.finish(
                identifier: AppConfiguration.receiverBackgroundSessionIdentifier
            )
        }
    }
}
