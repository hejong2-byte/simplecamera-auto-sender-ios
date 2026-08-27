import CryptoKit
import Foundation

enum USBReceiveServiceError: Error, Equatable {
    case missingRegistration
    case missingDestination
    case staleDestination
    case destinationChanged
    case destinationNotWritable
    case insufficientSpace
    case fat32FileTooLarge
    case invalidFileMetadata
    case sizeMismatch
    case shaMismatch
    case unexpectedRangeStatus(Int)
}

struct USBReceiveSummary: Equatable, Sendable {
    let discovered: Int
    let completed: Int
}

actor USBReceiveService {
    typealias CredentialsProvider = @Sendable () throws -> IPhoneReceiverCredentials?
    typealias DestinationProvider = @Sendable () throws -> USBBookmarkDestination?
    typealias VolumeIdentityProvider = @Sendable (URL) throws -> String?
    typealias VolumeFormatProvider = @Sendable (URL) throws -> String?

    static let defaultChunkSize: Int64 = 8 * 1_024 * 1_024
    static let partialDirectoryName = ".SimpleCameraReceiver"

    private let client: any IPhoneReceiverServing
    private let ledger: USBReceiveLedger
    private let credentials: CredentialsProvider
    private let destination: DestinationProvider
    private let chunkSize: Int64
    private let volumeIdentity: VolumeIdentityProvider
    private let volumeFormat: VolumeFormatProvider
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let progressStore: USBReceiveProgressStore

    init(
        client: any IPhoneReceiverServing,
        ledger: USBReceiveLedger,
        credentials: @escaping CredentialsProvider,
        destination: @escaping DestinationProvider,
        chunkSize: Int64 = USBReceiveService.defaultChunkSize,
        volumeIdentity: @escaping VolumeIdentityProvider = USBReceiveService.systemVolumeIdentity,
        volumeFormat: @escaping VolumeFormatProvider = USBReceiveService.systemVolumeFormat,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default,
        progressStore: USBReceiveProgressStore = USBReceiveProgressStore()
    ) {
        precondition(chunkSize > 0)
        self.client = client
        self.ledger = ledger
        self.credentials = credentials
        self.destination = destination
        self.chunkSize = chunkSize
        self.volumeIdentity = volumeIdentity
        self.volumeFormat = volumeFormat
        self.now = now
        self.fileManager = fileManager
        self.progressStore = progressStore
    }

    func runOnce() async throws -> USBReceiveSummary {
        do {
            return try await performRunOnce()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            progressStore.publishFailure(Self.errorMessage(error))
            throw error
        }
    }

    private func performRunOnce() async throws -> USBReceiveSummary {
        progressStore.publish(USBReceiveProgress(
            stage: .discovering,
            deliveryID: nil,
            fileName: nil,
            currentIndex: 0,
            totalCount: 0,
            completedCount: 0,
            bytesReceived: 0,
            totalBytes: 0,
            startedAt: now(),
            expiresAt: nil,
            errorMessage: nil
        ))
        guard let credentials = try credentials() else {
            throw USBReceiveServiceError.missingRegistration
        }
        guard let destination = try destination() else {
            throw USBReceiveServiceError.missingDestination
        }
        guard !destination.isStale else {
            throw USBReceiveServiceError.staleDestination
        }

        let accessed = destination.url.startAccessingSecurityScopedResource()
        defer {
            if accessed { destination.url.stopAccessingSecurityScopedResource() }
        }
        try validateDestination(destination)

        let acknowledged = try await retryAcknowledgements(
            credentials: credentials,
            destination: destination
        )
        let deliveries = try await client.list(
            receiverID: credentials.identity.receiverID,
            receiveSecret: credentials.secret
        )
        var completed = acknowledged.count
        for (offset, delivery) in deliveries.enumerated()
            where !acknowledged.contains(delivery.deliveryID) {
            try Task.checkCancellation()
            if delivery.state == .ackDeleting { continue }
            _ = try await client.lease(
                receiverID: credentials.identity.receiverID,
                deliveryID: delivery.deliveryID,
                receiveSecret: credentials.secret
            )
            try await receive(
                delivery,
                credentials: credentials,
                destination: destination,
                currentIndex: offset + 1,
                totalCount: deliveries.count,
                completedCount: completed
            )
            completed += 1
        }
        progressStore.publish(USBReceiveProgress(
            stage: .completed,
            deliveryID: nil,
            fileName: nil,
            currentIndex: deliveries.count,
            totalCount: deliveries.count,
            completedCount: completed,
            bytesReceived: 0,
            totalBytes: 0,
            startedAt: nil,
            expiresAt: nil,
            errorMessage: nil
        ))
        return USBReceiveSummary(discovered: deliveries.count, completed: completed)
    }

    private func validateDestination(_ destination: USBBookmarkDestination) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: destination.url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw USBReceiveServiceError.destinationNotWritable
        }
        if let currentVolume = try volumeIdentity(destination.url),
           currentVolume != destination.volumeID {
            throw USBReceiveServiceError.destinationChanged
        }
        let partialDirectory = partialDirectory(in: destination.url)
        do {
            try fileManager.createDirectory(
                at: partialDirectory,
                withIntermediateDirectories: true
            )
            let probe = partialDirectory.appendingPathComponent(
                ".write-probe-\(UUID().uuidString)"
            )
            try Data([0]).write(to: probe, options: .atomic)
            try fileManager.removeItem(at: probe)
        } catch {
            throw USBReceiveServiceError.destinationNotWritable
        }
    }

    private func retryAcknowledgements(
        credentials: IPhoneReceiverCredentials,
        destination: USBBookmarkDestination
    ) async throws -> Set<UUID> {
        var acknowledged: Set<UUID> = []
        let pending = ledger.allCheckpoints().filter { $0.state == .ackPending }
        for (offset, checkpoint) in pending.enumerated() {
            let finalURL = destination.url.appendingPathComponent(checkpoint.finalFileName)
            guard try fileMatches(
                finalURL,
                size: checkpoint.totalBytes,
                sha256: checkpoint.sha256
            ) else {
                var reset = checkpoint
                reset.confirmedOffset = 0
                reset.state = .downloading
                try ledger.save(reset)
                continue
            }
            progressStore.publish(USBReceiveProgress(
                stage: .acknowledging,
                deliveryID: checkpoint.deliveryID,
                fileName: checkpoint.fileName,
                currentIndex: offset + 1,
                totalCount: pending.count,
                completedCount: acknowledged.count,
                bytesReceived: checkpoint.totalBytes,
                totalBytes: checkpoint.totalBytes,
                startedAt: now(),
                expiresAt: nil,
                errorMessage: nil
            ))
            try await client.acknowledge(
                receiverID: credentials.identity.receiverID,
                deliveryID: checkpoint.deliveryID,
                receiveSecret: credentials.secret,
                sha256: checkpoint.sha256
            )
            try ledger.remove(deliveryID: checkpoint.deliveryID)
            acknowledged.insert(checkpoint.deliveryID)
        }
        return acknowledged
    }

    private func receive(
        _ delivery: IPhoneDelivery,
        credentials: IPhoneReceiverCredentials,
        destination: USBBookmarkDestination,
        currentIndex: Int,
        totalCount: Int,
        completedCount: Int
    ) async throws {
        let startedAt = now()
        let safeName = try validatedFileName(delivery)
        try USBVolumePolicy.validate(
            fileSize: delivery.size,
            formatDescription: try volumeFormat(destination.url)
        )
        var checkpoint = try checkpoint(
            for: delivery,
            safeName: safeName,
            destination: destination
        )
        var finalURL = destination.url.appendingPathComponent(checkpoint.finalFileName)

        if try fileMatches(finalURL, size: delivery.size, sha256: delivery.sha256) {
            checkpoint.confirmedOffset = delivery.size
            checkpoint.state = .ackPending
            try ledger.save(checkpoint)
            publish(
                .acknowledging,
                delivery: delivery,
                currentIndex: currentIndex,
                totalCount: totalCount,
                completedCount: completedCount,
                bytesReceived: delivery.size,
                startedAt: startedAt
            )
            try await acknowledge(delivery, credentials: credentials)
            try ledger.remove(deliveryID: delivery.deliveryID)
            return
        }

        let partialURL = partialURL(for: delivery.deliveryID, in: destination.url)
        if !fileManager.fileExists(atPath: partialURL.path) {
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw USBReceiveServiceError.destinationNotWritable
            }
        }
        let actualLength = try fileSize(partialURL)
        let resumeOffset = USBReceiveCheckpoint.safeResumeOffset(
            actualLength: actualLength,
            confirmedOffset: checkpoint.confirmedOffset,
            chunkSize: chunkSize
        )
        try truncateAndSynchronize(partialURL, to: resumeOffset)
        checkpoint.confirmedOffset = resumeOffset
        checkpoint.state = .downloading
        try ledger.save(checkpoint)
        publish(
            .downloading,
            delivery: delivery,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytesReceived: resumeOffset,
            startedAt: startedAt
        )
        try validateCapacity(
            at: destination.url,
            requiredBytes: delivery.size - resumeOffset
        )

        var hasher = SHA256()
        try hashPrefix(of: partialURL, length: resumeOffset, into: &hasher)
        let handle = try FileHandle(forWritingTo: partialURL)
        do {
            try handle.seek(toOffset: UInt64(resumeOffset))
            var offset = resumeOffset
            var lastLease = now()
            while offset < delivery.size {
                try Task.checkCancellation()
                if now().timeIntervalSince(lastLease) >= 120 {
                    _ = try await client.lease(
                        receiverID: credentials.identity.receiverID,
                        deliveryID: delivery.deliveryID,
                        receiveSecret: credentials.secret
                    )
                    lastLease = now()
                }
                let end = min(offset + chunkSize - 1, delivery.size - 1)
                let chunk = try await client.range(
                    receiverID: credentials.identity.receiverID,
                    deliveryID: delivery.deliveryID,
                    receiveSecret: credentials.secret,
                    start: offset,
                    end: end
                )
                guard chunk.statusCode == 206 else {
                    try handle.truncate(atOffset: 0)
                    try handle.synchronize()
                    checkpoint.confirmedOffset = 0
                    try ledger.save(checkpoint)
                    throw USBReceiveServiceError.unexpectedRangeStatus(chunk.statusCode)
                }
                try USBReceiveIntegrity.validateRange(
                    statusCode: chunk.statusCode,
                    contentRange: chunk.contentRange,
                    contentLength: chunk.contentLength,
                    expectedStart: offset,
                    expectedEnd: end,
                    totalBytes: delivery.size
                )
                guard Int64(chunk.data.count) == end - offset + 1 else {
                    throw USBReceiveServiceError.sizeMismatch
                }
                try handle.write(contentsOf: chunk.data)
                try handle.synchronize()
                hasher.update(data: chunk.data)
                offset += Int64(chunk.data.count)
                checkpoint.confirmedOffset = offset
                try ledger.save(checkpoint)
                publish(
                    .downloading,
                    delivery: delivery,
                    currentIndex: currentIndex,
                    totalCount: totalCount,
                    completedCount: completedCount,
                    bytesReceived: offset,
                    startedAt: startedAt
                )
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        checkpoint.state = .verifying
        try ledger.save(checkpoint)
        publish(
            .verifying,
            delivery: delivery,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytesReceived: delivery.size,
            startedAt: startedAt
        )
        guard try fileSize(partialURL) == delivery.size else {
            checkpoint.state = .failed
            try ledger.save(checkpoint)
            throw USBReceiveServiceError.sizeMismatch
        }
        let calculatedSHA = Self.hex(hasher.finalize())
        guard calculatedSHA == delivery.sha256.lowercased() else {
            checkpoint.state = .failed
            try ledger.save(checkpoint)
            throw USBReceiveServiceError.shaMismatch
        }

        if fileManager.fileExists(atPath: finalURL.path) {
            let selected = try availableFinalName(
                requestedName: safeName,
                delivery: delivery,
                in: destination.url
            )
            checkpoint.finalFileName = selected.name
            finalURL = destination.url.appendingPathComponent(selected.name)
            try ledger.save(checkpoint)
            if selected.reusesExistingFile {
                try fileManager.removeItem(at: partialURL)
            }
        }

        checkpoint.state = .finalizing
        try ledger.save(checkpoint)
        publish(
            .finalizing,
            delivery: delivery,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytesReceived: delivery.size,
            startedAt: startedAt
        )
        if fileManager.fileExists(atPath: partialURL.path) {
            try coordinatedMove(from: partialURL, to: finalURL)
        }
        guard try fileMatches(finalURL, size: delivery.size, sha256: delivery.sha256) else {
            try? fileManager.removeItem(at: finalURL)
            checkpoint.state = .failed
            try ledger.save(checkpoint)
            throw USBReceiveServiceError.shaMismatch
        }

        checkpoint.confirmedOffset = delivery.size
        checkpoint.state = .ackPending
        try ledger.save(checkpoint)
        publish(
            .acknowledging,
            delivery: delivery,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytesReceived: delivery.size,
            startedAt: startedAt
        )
        try await acknowledge(delivery, credentials: credentials)
        try ledger.remove(deliveryID: delivery.deliveryID)
    }

    private func checkpoint(
        for delivery: IPhoneDelivery,
        safeName: String,
        destination: USBBookmarkDestination
    ) throws -> USBReceiveCheckpoint {
        if let stored = ledger.checkpoint(for: delivery.deliveryID),
           stored.fileName == delivery.fileName,
           stored.sha256 == delivery.sha256,
           stored.totalBytes == delivery.size,
           stored.destinationVolumeID == destination.volumeID {
            return stored
        }
        let partial = partialURL(for: delivery.deliveryID, in: destination.url)
        try? fileManager.removeItem(at: partial)
        let selected = try availableFinalName(
            requestedName: safeName,
            delivery: delivery,
            in: destination.url
        )
        let checkpoint = USBReceiveCheckpoint(
            deliveryID: delivery.deliveryID,
            fileName: delivery.fileName,
            sha256: delivery.sha256,
            totalBytes: delivery.size,
            confirmedOffset: 0,
            destinationVolumeID: destination.volumeID,
            finalFileName: selected.name,
            state: selected.reusesExistingFile ? .ackPending : .downloading
        )
        try ledger.save(checkpoint)
        return checkpoint
    }

    private func availableFinalName(
        requestedName: String,
        delivery: IPhoneDelivery,
        in directory: URL
    ) throws -> (name: String, reusesExistingFile: Bool) {
        let name = (requestedName as NSString).deletingPathExtension
        let ext = (requestedName as NSString).pathExtension
        for suffix in 0...9_999 {
            let candidate: String
            if suffix == 0 {
                candidate = requestedName
            } else if ext.isEmpty {
                candidate = "\(name) (\(suffix))"
            } else {
                candidate = "\(name) (\(suffix)).\(ext)"
            }
            let url = directory.appendingPathComponent(candidate)
            if !fileManager.fileExists(atPath: url.path) {
                return (candidate, false)
            }
            if try fileMatches(url, size: delivery.size, sha256: delivery.sha256) {
                return (candidate, true)
            }
        }
        throw USBReceiveServiceError.destinationNotWritable
    }

    private func validatedFileName(_ delivery: IPhoneDelivery) throws -> String {
        let value = delivery.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentType = delivery.contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard delivery.size > 0,
              !value.isEmpty,
              value != ".",
              value != "..",
              value.count <= 240,
              !value.contains("/"),
              !value.contains("\\"),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              !contentType.isEmpty,
              contentType.count <= 127,
              contentType.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw USBReceiveServiceError.invalidFileMetadata
        }
        return value
    }

    private func validateCapacity(at url: URL, requiredBytes: Int64) throws {
        let attributes = try fileManager.attributesOfFileSystem(forPath: url.path)
        guard let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            return
        }
        if free < max(0, requiredBytes) {
            throw USBReceiveServiceError.insufficientSpace
        }
    }

    private func fileMatches(_ url: URL, size: Int64, sha256: String) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              try fileSize(url) == size else { return false }
        return try hashFile(url) == sha256.lowercased()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return Self.hex(hasher.finalize())
    }

    private func hashPrefix(
        of url: URL,
        length: Int64,
        into hasher: inout SHA256
    ) throws {
        guard length > 0 else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = length
        while remaining > 0 {
            let count = Int(min(remaining, 1_024 * 1_024))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                throw USBReceiveServiceError.sizeMismatch
            }
            hasher.update(data: data)
            remaining -= Int64(data.count)
        }
    }

    private func truncateAndSynchronize(_ url: URL, to offset: Int64) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.truncate(atOffset: UInt64(offset))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source,
            options: .forMoving,
            error: &coordinationError
        ) { coordinatedSource in
            do {
                try fileManager.moveItem(at: coordinatedSource, to: destination)
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }

    private func acknowledge(
        _ delivery: IPhoneDelivery,
        credentials: IPhoneReceiverCredentials
    ) async throws {
        try await client.acknowledge(
            receiverID: credentials.identity.receiverID,
            deliveryID: delivery.deliveryID,
            receiveSecret: credentials.secret,
            sha256: delivery.sha256
        )
    }

    private func partialDirectory(in destination: URL) -> URL {
        destination.appendingPathComponent(Self.partialDirectoryName, isDirectory: true)
    }

    private func partialURL(for deliveryID: UUID, in destination: URL) -> URL {
        partialDirectory(in: destination).appendingPathComponent(
            deliveryID.uuidString.lowercased() + ".partial"
        )
    }

    private func publish(
        _ stage: USBReceiveStage,
        delivery: IPhoneDelivery,
        currentIndex: Int,
        totalCount: Int,
        completedCount: Int,
        bytesReceived: Int64,
        startedAt: Date
    ) {
        progressStore.publish(USBReceiveProgress(
            stage: stage,
            deliveryID: delivery.deliveryID,
            fileName: delivery.fileName,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytesReceived: bytesReceived,
            totalBytes: delivery.size,
            startedAt: startedAt,
            expiresAt: delivery.expiresAt,
            errorMessage: nil
        ))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func systemVolumeIdentity(_ url: URL) throws -> String? {
        try url.resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier
            .map { String(describing: $0) }
    }

    private static func systemVolumeFormat(_ url: URL) throws -> String? {
        try url.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey])
            .volumeLocalizedFormatDescription
    }

    private static func errorMessage(_ error: Error) -> String {
        if let serviceError = error as? USBReceiveServiceError {
            return String(describing: serviceError)
        }
        if let clientError = error as? IPhoneReceiverClientError {
            return String(describing: clientError)
        }
        return String(describing: error)
    }
}
