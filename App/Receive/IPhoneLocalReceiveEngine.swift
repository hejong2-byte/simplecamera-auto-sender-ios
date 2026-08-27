import CryptoKit
import Foundation

enum IPhoneLocalReceiveError: Error, Equatable {
    case receiverNotRegistered
    case missingJob
    case invalidFileName
    case fileNameUnavailable
    case sizeMismatch
    case shaMismatch
    case finalFileChanged
}

enum IPhoneLocalFileNaming {
    static let maximumNameBytes = 240

    static func availableName(
        requestedName: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let value = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafe(value) else { throw IPhoneLocalReceiveError.invalidFileName }
        for suffix in 0...9_999 {
            let candidate = try candidateName(value, suffix: suffix)
            let url = directory.appendingPathComponent(candidate, isDirectory: false)
            if !fileManager.fileExists(atPath: url.path) { return candidate }
        }
        throw IPhoneLocalReceiveError.fileNameUnavailable
    }

    static func candidateName(_ requestedName: String, suffix: Int) throws -> String {
        let original = requestedName as NSString
        let pathExtension = original.pathExtension
        let base = original.deletingPathExtension
        let suffixText = suffix == 0 ? "" : " (\(suffix))"
        let extensionText = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let reservedBytes = suffixText.lengthOfBytes(using: .utf8)
            + extensionText.lengthOfBytes(using: .utf8)
        let maximumBaseBytes = maximumNameBytes - reservedBytes
        guard maximumBaseBytes > 0 else {
            throw IPhoneLocalReceiveError.invalidFileName
        }
        var shortened = ""
        for character in base {
            let next = shortened + String(character)
            if next.lengthOfBytes(using: .utf8) > maximumBaseBytes { break }
            shortened = next
        }
        if shortened.isEmpty {
            guard "file".lengthOfBytes(using: .utf8) <= maximumBaseBytes else {
                throw IPhoneLocalReceiveError.invalidFileName
            }
            shortened = "file"
        }
        return shortened + suffixText + extensionText
    }

    private static func isSafe(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

actor IPhoneLocalReceiveEngine: IPhoneReceiveDownloadSink {
    private let client: any IPhoneLocalReceiveNetworking
    private let scheduler: any IPhoneReceiveTaskScheduling
    private let jobStore: IPhoneLocalReceiveJobStore
    private let catalog: IPhoneReceivedFileCatalog
    private let credentials: @Sendable () throws -> IPhoneReceiverCredentials?
    private let progressStore: USBReceiveProgressStore
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        client: any IPhoneLocalReceiveNetworking,
        scheduler: any IPhoneReceiveTaskScheduling,
        jobStore: IPhoneLocalReceiveJobStore,
        catalog: IPhoneReceivedFileCatalog,
        credentials: @escaping @Sendable () throws -> IPhoneReceiverCredentials?,
        progressStore: USBReceiveProgressStore,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.scheduler = scheduler
        self.jobStore = jobStore
        self.catalog = catalog
        self.credentials = credentials
        self.progressStore = progressStore
        self.fileManager = fileManager
        self.now = now
    }

    func discoverAndSchedule() async throws {
        let credentials = try requiredCredentials()
        try await client.updateFeatures(
            receiverID: credentials.identity.receiverID,
            receiveSecret: credentials.secret,
            features: .current
        )
        let current = try jobStore.load().jobs
        if current.contains(where: { ![.completed, .failed].contains($0.stage) }) {
            return
        }
        publish(stage: .discovering, job: nil)
        let deliveries = try await client.list(
            receiverID: credentials.identity.receiverID,
            receiveSecret: credentials.secret
        ).filter { $0.state == .available || $0.state == .leased }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.deliveryID.uuidString < $1.deliveryID.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
        let known = Set(current.map { $0.delivery.deliveryID })
        let existingTasks = await scheduler.existingDeliveryIDs()
        guard let delivery = deliveries.first(where: {
            !known.contains($0.deliveryID) && !existingTasks.contains($0.deliveryID)
        }) else { return }
        var job = IPhoneLocalReceiveJob(
            id: delivery.deliveryID,
            delivery: delivery,
            stage: .scheduled,
            stagingFileName: nil,
            finalFileName: nil,
            bytesReceived: 0,
            retryCount: 0,
            lastError: nil
        )
        try jobStore.save(job)
        do {
            _ = try await client.lease(
                receiverID: credentials.identity.receiverID,
                deliveryID: delivery.deliveryID,
                receiveSecret: credentials.secret,
                mode: .background
            )
            let request = try client.downloadRequest(
                receiverID: credentials.identity.receiverID,
                deliveryID: delivery.deliveryID,
                receiveSecret: credentials.secret
            )
            try await scheduler.schedule(
                deliveryID: delivery.deliveryID,
                request: request
            )
            job.stage = .downloading
            try jobStore.save(job)
            publish(stage: .downloading, job: job)
        } catch {
            job.lastError = String(describing: error)
            try? jobStore.save(job)
            throw error
        }
    }

    func restore() async {
        do {
            let jobs = try jobStore.load().jobs
            if let pending = jobs.first(where: { $0.stage == .ackPending }) {
                await retryAcknowledgement(pending)
                return
            }
            if let finalizing = jobs.first(where: {
                [.downloaded, .verifying, .finalizing].contains($0.stage)
            }), let stagingName = finalizing.stagingFileName {
                await finalize(
                    finalizing,
                    stagingURL: catalog.stagingDirectory
                        .appendingPathComponent(stagingName)
                )
                return
            }
            if let active = jobs.first(where: {
                [.scheduled, .downloading].contains($0.stage)
            }) {
                let existing = await scheduler.existingDeliveryIDs()
                if existing.contains(active.delivery.deliveryID) { return }
                try await reschedule(active)
                return
            }
            try await discoverAndSchedule()
        } catch {
            progressStore.publishFailure(String(describing: error))
        }
    }

    func downloadProgress(deliveryID: UUID, received: Int64, expected: Int64) async {
        guard var job = jobStore.job(for: deliveryID) else { return }
        job.stage = .downloading
        job.bytesReceived = max(0, received)
        job.lastError = nil
        try? jobStore.save(job)
        publish(stage: .downloading, job: job)
    }

    func downloadFinished(deliveryID: UUID, stagingURL: URL) async {
        guard var job = jobStore.job(for: deliveryID) else {
            progressStore.publishFailure(
                String(describing: IPhoneLocalReceiveError.missingJob)
            )
            return
        }
        do {
            job.stage = .downloaded
            job.stagingFileName = stagingURL.lastPathComponent
            job.bytesReceived = try fileSize(stagingURL)
            job.lastError = nil
            try jobStore.save(job)
            await finalize(job, stagingURL: stagingURL)
        } catch {
            await markFailed(job, error: error)
        }
    }

    func downloadFailed(deliveryID: UUID, error: Error) async {
        guard let job = jobStore.job(for: deliveryID) else { return }
        await markFailed(job, error: error)
    }

    private func finalize(
        _ initial: IPhoneLocalReceiveJob,
        stagingURL: URL
    ) async {
        var job = initial
        do {
            job.stage = .verifying
            try jobStore.save(job)
            publish(stage: .verifying, job: job)
            try verify(
                stagingURL,
                size: job.delivery.size,
                sha256: job.delivery.sha256
            )

            let storedName: String
            if let reserved = job.finalFileName {
                storedName = reserved
            } else {
                storedName = try IPhoneLocalFileNaming.availableName(
                    requestedName: job.delivery.fileName,
                    in: catalog.receivedDirectory,
                    fileManager: fileManager
                )
                job.finalFileName = storedName
            }
            job.stage = .finalizing
            try jobStore.save(job)
            publish(stage: .finalizing, job: job)
            let finalURL = catalog.receivedDirectory.appendingPathComponent(storedName)
            if fileManager.fileExists(atPath: finalURL.path) {
                try verify(
                    finalURL,
                    size: job.delivery.size,
                    sha256: job.delivery.sha256
                )
            } else {
                try coordinatedCopy(from: stagingURL, to: finalURL)
                do {
                    try verify(
                        finalURL,
                        size: job.delivery.size,
                        sha256: job.delivery.sha256
                    )
                } catch {
                    try? fileManager.removeItem(at: finalURL)
                    throw error
                }
            }
            try catalog.save(IPhoneReceivedFileRecord(
                deliveryID: job.delivery.deliveryID,
                originalName: job.delivery.fileName,
                storedName: storedName,
                size: job.delivery.size,
                sha256: job.delivery.sha256,
                receivedAt: now()
            ))
            job.stage = .ackPending
            job.bytesReceived = job.delivery.size
            job.lastError = nil
            try jobStore.save(job)
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            await retryAcknowledgement(job)
        } catch {
            await markFailed(job, error: error)
        }
    }

    private func retryAcknowledgement(_ initial: IPhoneLocalReceiveJob) async {
        var job = initial
        do {
            let credentials = try requiredCredentials()
            guard let storedName = job.finalFileName else {
                throw IPhoneLocalReceiveError.finalFileChanged
            }
            let finalURL = catalog.receivedDirectory.appendingPathComponent(storedName)
            try verify(
                finalURL,
                size: job.delivery.size,
                sha256: job.delivery.sha256
            )
            publish(stage: .acknowledging, job: job)
            try await client.acknowledge(
                receiverID: credentials.identity.receiverID,
                deliveryID: job.delivery.deliveryID,
                receiveSecret: credentials.secret,
                sha256: job.delivery.sha256,
                storageLocation: .iphoneLocal,
                storedName: storedName
            )
            job.stage = .completed
            job.lastError = nil
            try jobStore.save(job)
            publish(stage: .completed, job: job)
            try? await discoverAndSchedule()
        } catch {
            job.stage = .ackPending
            job.retryCount += 1
            job.lastError = String(describing: error)
            try? jobStore.save(job)
            progressStore.publishFailure(job.lastError ?? "ACK failed")
        }
    }

    private func reschedule(_ initial: IPhoneLocalReceiveJob) async throws {
        var job = initial
        let credentials = try requiredCredentials()
        _ = try await client.lease(
            receiverID: credentials.identity.receiverID,
            deliveryID: job.delivery.deliveryID,
            receiveSecret: credentials.secret,
            mode: .background
        )
        let request = try client.downloadRequest(
            receiverID: credentials.identity.receiverID,
            deliveryID: job.delivery.deliveryID,
            receiveSecret: credentials.secret
        )
        try await scheduler.schedule(
            deliveryID: job.delivery.deliveryID,
            request: request
        )
        job.stage = .downloading
        job.lastError = nil
        try jobStore.save(job)
        publish(stage: .downloading, job: job)
    }

    private func markFailed(_ initial: IPhoneLocalReceiveJob, error: Error) async {
        var job = initial
        job.stage = .failed
        job.lastError = String(describing: error)
        try? jobStore.save(job)
        progressStore.publishFailure(job.lastError ?? "receive failed")
        try? await discoverAndSchedule()
    }

    private func requiredCredentials() throws -> IPhoneReceiverCredentials {
        guard let value = try credentials() else {
            throw IPhoneLocalReceiveError.receiverNotRegistered
        }
        return value
    }

    private func publish(stage: USBReceiveStage, job: IPhoneLocalReceiveJob?) {
        progressStore.publish(USBReceiveProgress(
            stage: stage,
            destination: .iphoneLocal,
            deliveryID: job?.delivery.deliveryID,
            fileName: job?.delivery.fileName,
            currentIndex: job == nil ? 0 : 1,
            totalCount: job == nil ? 0 : 1,
            completedCount: stage == .completed ? 1 : 0,
            bytesReceived: job?.bytesReceived ?? 0,
            totalBytes: job?.delivery.size ?? 0,
            startedAt: job == nil ? nil : now(),
            expiresAt: job?.delivery.expiresAt,
            errorMessage: nil
        ))
    }

    private func verify(_ url: URL, size: Int64, sha256: String) throws {
        guard try fileSize(url) == size else {
            throw IPhoneLocalReceiveError.sizeMismatch
        }
        guard try hashFile(url) == sha256.lowercased() else {
            throw IPhoneLocalReceiveError.shaMismatch
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw IPhoneLocalReceiveError.sizeMismatch
        }
        return Int64(values.fileSize ?? 0)
    }

    private func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source,
            options: [],
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                guard !fileManager.fileExists(atPath: coordinatedDestination.path) else {
                    throw IPhoneLocalReceiveError.fileNameUnavailable
                }
                try fileManager.copyItem(
                    at: coordinatedSource,
                    to: coordinatedDestination
                )
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }
}
