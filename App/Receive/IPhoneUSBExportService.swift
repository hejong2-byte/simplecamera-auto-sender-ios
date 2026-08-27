import CryptoKit
import Foundation

enum IPhoneUSBExportError: String, Error, Codable, Equatable, Sendable {
    case staleDestination
    case destinationAccessDenied
    case destinationChanged
    case destinationNotWritable
    case insufficientSpace
    case sourceChanged
    case sizeMismatch
    case shaMismatch
    case copyFailed
}

struct IPhoneUSBExportFailure: Equatable, Sendable {
    let sourceID: String
    let error: IPhoneUSBExportError
}

struct IPhoneUSBDeletionDecision: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let sourceID: String
    let sourceURL: URL
    let sourceSize: Int64
    let sourceSHA256: String
    let usbStoredName: String
    let verifiedAt: Date
}

struct IPhoneUSBExportSummary: Equatable, Sendable {
    let verified: [IPhoneUSBDeletionDecision]
    let failed: [IPhoneUSBExportFailure]
}

struct IPhoneUSBDeletionSummary: Equatable, Sendable {
    let deletedSourceIDs: [String]
    let failed: [IPhoneUSBExportFailure]
}

final class IPhoneUSBDeletionDecisionStore: @unchecked Sendable {
    private struct State: Codable {
        let version: Int
        var decisions: [IPhoneUSBDeletionDecision]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var state: State

    init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        if fileManager.fileExists(atPath: fileURL.path) {
            state = try JSONDecoder().decode(
                State.self,
                from: Data(contentsOf: fileURL)
            )
        } else {
            state = State(version: 1, decisions: [])
        }
    }

    func pending() -> [IPhoneUSBDeletionDecision] {
        lock.withLock { state.decisions }
    }

    func save(_ decision: IPhoneUSBDeletionDecision) throws {
        try lock.withLock {
            var next = state
            next.decisions.removeAll {
                $0.id == decision.id || $0.sourceID == decision.sourceID
            }
            next.decisions.append(decision)
            try persist(next)
            state = next
        }
    }

    func remove(ids: Set<UUID>) throws {
        try lock.withLock {
            var next = state
            next.decisions.removeAll { ids.contains($0.id) }
            try persist(next)
            state = next
        }
    }

    private func persist(_ value: State) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
    }
}

actor IPhoneUSBExportService {
    typealias SecurityScopeStart = @Sendable (URL) -> Bool
    typealias SecurityScopeStop = @Sendable (URL) -> Void
    typealias VolumeIdentity = @Sendable (URL) throws -> String?
    typealias AvailableCapacity = @Sendable (URL) throws -> Int64?

    static let partialDirectoryName = USBReceiveService.partialDirectoryName

    private let deletionStore: IPhoneUSBDeletionDecisionStore
    private let fileManager: FileManager
    private let startAccessing: SecurityScopeStart
    private let stopAccessing: SecurityScopeStop
    private let volumeIdentity: VolumeIdentity
    private let availableCapacity: AvailableCapacity
    private let progressStore: USBReceiveProgressStore
    private let now: @Sendable () -> Date

    init(
        deletionStore: IPhoneUSBDeletionDecisionStore,
        fileManager: FileManager = .default,
        startAccessing: @escaping SecurityScopeStart = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccessing: @escaping SecurityScopeStop = {
            $0.stopAccessingSecurityScopedResource()
        },
        volumeIdentity: @escaping VolumeIdentity = IPhoneUSBExportService.systemVolumeIdentity,
        availableCapacity: @escaping AvailableCapacity = IPhoneUSBExportService.systemAvailableCapacity,
        progressStore: USBReceiveProgressStore = USBReceiveProgressStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.deletionStore = deletionStore
        self.fileManager = fileManager
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.volumeIdentity = volumeIdentity
        self.availableCapacity = availableCapacity
        self.progressStore = progressStore
        self.now = now
    }

    func export(
        _ files: [IPhoneStoredFile],
        to destination: USBBookmarkDestination
    ) -> IPhoneUSBExportSummary {
        var verified: [IPhoneUSBDeletionDecision] = []
        var failed: [IPhoneUSBExportFailure] = []
        for (index, file) in files.enumerated() {
            do {
                let decision = try exportOne(
                    file,
                    to: destination,
                    currentIndex: index + 1,
                    totalCount: files.count,
                    completedCount: verified.count
                )
                verified.append(decision)
            } catch {
                failed.append(IPhoneUSBExportFailure(
                    sourceID: file.id,
                    error: Self.normalizedError(error)
                ))
            }
        }
        if failed.isEmpty {
            progressStore.publish(USBReceiveProgress(
                stage: .completed,
                destination: .usb,
                deliveryID: nil,
                fileName: nil,
                currentIndex: files.count,
                totalCount: files.count,
                completedCount: verified.count,
                bytesReceived: 0,
                totalBytes: 0,
                startedAt: nil,
                expiresAt: nil,
                errorMessage: nil
            ))
        } else {
            progressStore.publishFailure(
                "USB 복사 완료 \(verified.count)개, 실패 \(failed.count)개"
            )
        }
        return IPhoneUSBExportSummary(verified: verified, failed: failed)
    }

    func keep(decisionIDs: Set<UUID>) throws {
        try deletionStore.remove(ids: decisionIDs)
    }

    func delete(decisionIDs: Set<UUID>) -> IPhoneUSBDeletionSummary {
        let selected = deletionStore.pending().filter { decisionIDs.contains($0.id) }
        var deleted: [String] = []
        var failed: [IPhoneUSBExportFailure] = []
        for decision in selected {
            do {
                guard try fileSize(decision.sourceURL) == decision.sourceSize,
                      try hashFile(decision.sourceURL) == decision.sourceSHA256 else {
                    throw IPhoneUSBExportError.sourceChanged
                }
                try fileManager.removeItem(at: decision.sourceURL)
                try deletionStore.remove(ids: [decision.id])
                deleted.append(decision.sourceID)
            } catch {
                failed.append(IPhoneUSBExportFailure(
                    sourceID: decision.sourceID,
                    error: Self.normalizedError(error)
                ))
            }
        }
        return IPhoneUSBDeletionSummary(
            deletedSourceIDs: deleted,
            failed: failed
        )
    }

    private func exportOne(
        _ file: IPhoneStoredFile,
        to destination: USBBookmarkDestination,
        currentIndex: Int,
        totalCount: Int,
        completedCount: Int
    ) throws -> IPhoneUSBDeletionDecision {
        guard !destination.isStale else {
            throw IPhoneUSBExportError.staleDestination
        }
        guard startAccessing(destination.url) else {
            throw IPhoneUSBExportError.destinationAccessDenied
        }
        defer { stopAccessing(destination.url) }
        try validateDestination(destination)

        let sourceSize = try fileSize(file.url)
        if let record = file.receivedRecord, record.size != sourceSize {
            throw IPhoneUSBExportError.sourceChanged
        }
        if let free = try availableCapacity(destination.url), free < sourceSize {
            throw IPhoneUSBExportError.insufficientSpace
        }

        let partialDirectory = destination.url.appendingPathComponent(
            Self.partialDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: partialDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = partialDirectory.appendingPathComponent(
            "export-\(UUID().uuidString.lowercased()).partial"
        )
        guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
            throw IPhoneUSBExportError.destinationNotWritable
        }
        defer { try? fileManager.removeItem(at: partialURL) }

        publish(
            file: file,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytes: 0
        )
        let sourceSHA = try copyAndHash(
            source: file.url,
            destination: partialURL,
            progress: { bytes in
                self.publish(
                    file: file,
                    currentIndex: currentIndex,
                    totalCount: totalCount,
                    completedCount: completedCount,
                    bytes: bytes
                )
            }
        )
        guard try fileSize(partialURL) == sourceSize else {
            throw IPhoneUSBExportError.sizeMismatch
        }
        if let expected = file.receivedRecord?.sha256.lowercased(), expected != sourceSHA {
            throw IPhoneUSBExportError.shaMismatch
        }

        let storedName = try IPhoneLocalFileNaming.availableName(
            requestedName: file.name,
            in: destination.url,
            fileManager: fileManager
        )
        let finalURL = destination.url.appendingPathComponent(storedName)
        try coordinatedMove(from: partialURL, to: finalURL)
        do {
            guard try fileSize(finalURL) == sourceSize else {
                throw IPhoneUSBExportError.sizeMismatch
            }
            guard try hashFile(finalURL) == sourceSHA else {
                throw IPhoneUSBExportError.shaMismatch
            }
        } catch {
            try? fileManager.removeItem(at: finalURL)
            throw error
        }

        let decision = IPhoneUSBDeletionDecision(
            id: UUID(),
            sourceID: file.id,
            sourceURL: file.url,
            sourceSize: sourceSize,
            sourceSHA256: sourceSHA,
            usbStoredName: storedName,
            verifiedAt: now()
        )
        try deletionStore.save(decision)
        return decision
    }

    private func validateDestination(_ destination: USBBookmarkDestination) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: destination.url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw IPhoneUSBExportError.destinationNotWritable
        }
        guard let currentVolume = try volumeIdentity(destination.url),
              currentVolume == destination.volumeID else {
            throw IPhoneUSBExportError.destinationChanged
        }
        let probe = destination.url.appendingPathComponent(
            ".write-probe-\(UUID().uuidString)"
        )
        do {
            try Data([0]).write(to: probe, options: .atomic)
            try fileManager.removeItem(at: probe)
        } catch {
            try? fileManager.removeItem(at: probe)
            throw IPhoneUSBExportError.destinationNotWritable
        }
    }

    private func copyAndHash(
        source: URL,
        destination: URL,
        progress: (Int64) -> Void
    ) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        var hasher = SHA256()
        var copied: Int64 = 0
        do {
            while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                try output.write(contentsOf: data)
                hasher.update(data: data)
                copied += Int64(data.count)
                progress(copied)
            }
            try output.synchronize()
            try input.close()
            try output.close()
        } catch {
            try? input.close()
            try? output.close()
            throw error
        }
        return Self.hex(hasher.finalize())
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw IPhoneUSBExportError.sourceChanged
        }
        return Int64(values.fileSize ?? 0)
    }

    private func hashFile(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return Self.hex(hasher.finalize())
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

    private func publish(
        file: IPhoneStoredFile,
        currentIndex: Int,
        totalCount: Int,
        completedCount: Int,
        bytes: Int64
    ) {
        progressStore.publish(USBReceiveProgress(
            stage: .copyingToUSB,
            destination: .usb,
            deliveryID: file.receivedRecord?.deliveryID,
            fileName: file.name,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytesReceived: bytes,
            totalBytes: file.size,
            startedAt: now(),
            expiresAt: nil,
            errorMessage: nil
        ))
    }

    private static func normalizedError(_ error: Error) -> IPhoneUSBExportError {
        (error as? IPhoneUSBExportError) ?? .copyFailed
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func systemVolumeIdentity(_ url: URL) throws -> String? {
        try url.resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier
            .map { String(describing: $0) }
    }

    private static func systemAvailableCapacity(_ url: URL) throws -> Int64? {
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: url.path
        )
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
