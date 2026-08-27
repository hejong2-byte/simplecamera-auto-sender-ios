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
    let detail: String?

    init(sourceID: String, error: IPhoneUSBExportError, detail: String? = nil) {
        self.sourceID = sourceID
        self.error = error
        self.detail = detail
    }

    var message: String { detail ?? IPhoneReceiveErrorMessage.message(error) }
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

    var errorMessage: String? {
        guard let first = failed.first else { return nil }
        return "USB 복사 완료 \(verified.count)개, 실패 \(failed.count)개\n\(first.message)"
    }
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

    static let partialDirectoryName = USBReceiveService.partialDirectoryName

    private let deletionStore: IPhoneUSBDeletionDecisionStore
    private let fileManager: FileManager
    private let startAccessing: SecurityScopeStart
    private let stopAccessing: SecurityScopeStop
    private let volumeIdentity: VolumeIdentity
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
        progressStore: USBReceiveProgressStore = USBReceiveProgressStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.deletionStore = deletionStore
        self.fileManager = fileManager
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.volumeIdentity = volumeIdentity
        self.progressStore = progressStore
        self.now = now
    }

    func export(
        _ files: [IPhoneStoredFile],
        to destination: USBBookmarkDestination
    ) -> IPhoneUSBExportSummary {
        guard !files.isEmpty else {
            return IPhoneUSBExportSummary(verified: [], failed: [])
        }
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
                failed.append(Self.failure(sourceID: file.id, error: error))
            }
        }
        let summary = IPhoneUSBExportSummary(verified: verified, failed: failed)
        if failed.isEmpty {
            let copiedBytes = verified.reduce(Int64(0)) { $0 + $1.sourceSize }
            progressStore.publish(USBReceiveProgress(
                stage: .completed,
                destination: .usb,
                deliveryID: nil,
                fileName: nil,
                currentIndex: files.count,
                totalCount: files.count,
                completedCount: verified.count,
                bytesReceived: copiedBytes,
                totalBytes: copiedBytes,
                startedAt: nil,
                expiresAt: nil,
                errorMessage: nil
            ))
        } else {
            let failedIndex = files.firstIndex { $0.id == failed[0].sourceID } ?? 0
            let failedFile = files[failedIndex]
            progressStore.publish(USBReceiveProgress(
                stage: .failed,
                destination: .usb,
                deliveryID: failedFile.receivedRecord?.deliveryID,
                fileName: failedFile.name,
                currentIndex: failedIndex + 1,
                totalCount: files.count,
                completedCount: verified.count,
                bytesReceived: 0,
                totalBytes: failedFile.size,
                startedAt: nil,
                expiresAt: nil,
                errorMessage: summary.errorMessage
            ))
        }
        return summary
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
                failed.append(Self.failure(sourceID: decision.sourceID, error: error))
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
        let startedAt = now()
        publish(
            file: file,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytes: 0,
            startedAt: startedAt
        )
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
        // Do not reject USB exports based on a capacity estimate. Actual write errors
        // stop the copy, and size/hash verification below gates completion.

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

        let sourceSHA = try copyAndHash(
            source: file.url,
            destination: partialURL,
            progress: { bytes in
                self.publish(
                    file: file,
                    currentIndex: currentIndex,
                    totalCount: totalCount,
                    completedCount: completedCount,
                    bytes: bytes,
                    startedAt: startedAt
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
        publish(
            file: file,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytes: sourceSize,
            startedAt: startedAt,
            stage: .verifying
        )
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
        // Match USBBookmarkStore's fallback when the provider has no volume identifier.
        let currentVolume = try volumeIdentity(destination.url) ?? destination.url.path
        guard currentVolume == destination.volumeID else {
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
        bytes: Int64,
        startedAt: Date,
        stage: USBReceiveStage = .copyingToUSB
    ) {
        progressStore.publish(USBReceiveProgress(
            stage: stage,
            destination: .usb,
            deliveryID: file.receivedRecord?.deliveryID,
            fileName: file.name,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytesReceived: bytes,
            totalBytes: file.size,
            startedAt: startedAt,
            expiresAt: nil,
            errorMessage: nil
        ))
    }

    private static func failure(sourceID: String, error: Error) -> IPhoneUSBExportFailure {
        if let known = error as? IPhoneUSBExportError {
            return IPhoneUSBExportFailure(sourceID: sourceID, error: known)
        }
        let systemError = error as NSError
        let outOfSpace = (systemError.domain == NSCocoaErrorDomain
            && systemError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue)
            || (systemError.domain == NSPOSIXErrorDomain
                && systemError.code == Int(POSIXErrorCode.ENOSPC.rawValue))
        let normalized: IPhoneUSBExportError = outOfSpace ? .insufficientSpace : .copyFailed
        return IPhoneUSBExportFailure(
            sourceID: sourceID,
            error: normalized,
            detail: "\(IPhoneReceiveErrorMessage.message(normalized)) (\(systemError.domain) · \(systemError.code))"
        )
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func systemVolumeIdentity(_ url: URL) throws -> String? {
        try url.resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier
            .map { String(describing: $0) }
    }
}
