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
    case unsafeZIPArchive
    case zipExtractionFailed
    case copyFailed
    case verificationRecordMissing
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

struct USBCopyFileDigest: Codable, Equatable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
}

struct IPhoneUSBDeletionDecision: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let sourceID: String
    let sourceURL: URL
    let sourceSize: Int64
    let sourceSHA256: String
    let usbStoredName: String
    let verifiedAt: Date
    // Absent for legacy SHA-verified deletion decisions.
    var copiedFiles: [USBCopyFileDigest]? = nil
    var usbVolumeID: String? = nil
    var sourceModifiedAt: Date? = nil
}

struct IPhoneUSBExportSummary: Equatable, Sendable {
    let verified: [IPhoneUSBDeletionDecision]
    let failed: [IPhoneUSBExportFailure]
    var cancelled = false
    var cleanupWarning: String? = nil

    var errorMessage: String? {
        guard let first = failed.first else { return nil }
        return "USB 복사 완료 \(verified.count)개, 실패 \(failed.count)개\n\(first.message)"
    }
}

struct IPhoneUSBDeletionSummary: Equatable, Sendable {
    let deletedSourceIDs: [String]
    let failed: [IPhoneUSBExportFailure]
}

struct USBExportTemporaryCleanupSummary: Equatable, Sendable {
    var deletedCount = 0
    var failures: [String] = []
    var usbChecked = false
}

final class IPhoneUSBDeletionDecisionStore: @unchecked Sendable {
    private struct State: Codable {
        let version: Int
        var decisions: [IPhoneUSBDeletionDecision]
        var copies: [IPhoneUSBDeletionDecision]? = nil
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var state: State

    init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        state = PersistedStateRecovery.decodeOrRecover(
            State.self,
            from: fileURL,
            fallback: State(version: 1, decisions: []),
            fileManager: fileManager
        )
    }

    func pending() -> [IPhoneUSBDeletionDecision] {
        lock.withLock { state.decisions }
    }

    func copies() -> [IPhoneUSBDeletionDecision] {
        lock.withLock { state.copies ?? [] }
    }

    func save(_ decision: IPhoneUSBDeletionDecision) throws {
        try lock.withLock {
            var next = state
            next.decisions.removeAll {
                $0.id == decision.id || $0.sourceID == decision.sourceID
            }
            next.decisions.append(decision)
            if decision.copiedFiles != nil {
                var copies = next.copies ?? []
                copies.removeAll { $0.sourceID == decision.sourceID && $0.usbVolumeID == decision.usbVolumeID }
                copies.append(decision)
                next.copies = copies
            }
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
    typealias CoordinateWrite = @Sendable (URL, (URL) throws -> Void) throws -> Void

    static let partialDirectoryName = USBReceiveService.partialDirectoryName

    private let deletionStore: IPhoneUSBDeletionDecisionStore
    private let fileManager: FileManager
    private let startAccessing: SecurityScopeStart
    private let stopAccessing: SecurityScopeStop
    private let volumeIdentity: VolumeIdentity
    private let progressStore: USBReceiveProgressStore
    private let zipWorkingDirectory: URL
    private let now: @Sendable () -> Date
    private let coordinateWrite: CoordinateWrite
    private var cleanupFailures: [String] = []

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
        zipWorkingDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleCamera-ZIP-Export", isDirectory: true),
        now: @escaping @Sendable () -> Date = Date.init,
        coordinateWrite: @escaping CoordinateWrite = IPhoneUSBExportService.coordinateWriteSystem
    ) {
        self.deletionStore = deletionStore
        self.fileManager = fileManager
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.volumeIdentity = volumeIdentity
        self.progressStore = progressStore
        self.zipWorkingDirectory = zipWorkingDirectory
        self.now = now
        self.coordinateWrite = coordinateWrite
    }

    static func coordinateWriteSystem(_ url: URL, operation: (URL) throws -> Void) throws {
        try operation(url)
    }

    func cleanupTemporaryFiles(to destination: USBBookmarkDestination?,
                               progress: @Sendable (FileDeletionProgress) -> Void = { _ in }) -> USBExportTemporaryCleanupSummary {
        var result = USBExportTemporaryCleanupSummary()
        var candidates: [URL] = []
        var scopedURL: URL?
        defer { if let scopedURL { stopAccessing(scopedURL) } }
        func collect(in root: URL, prefix: String, suffix: String) {
            do {
                guard fileManager.fileExists(atPath: root.path) else { return }
                let attributes = try fileManager.attributesOfItem(atPath: root.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw IPhoneUSBExportError.destinationAccessDenied
                }
                for child in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    let name = child.lastPathComponent
                    guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                          UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil else { continue }
                    guard child.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path,
                          try fileManager.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType != .typeSymbolicLink else {
                        result.failures.append("안전 확인 실패 · \(name)")
                        continue
                    }
                    candidates.append(child)
                }
            } catch {
                result.failures.append("임시폴더 확인 실패 · \(root.lastPathComponent): \(error.localizedDescription)")
            }
        }
        collect(in: zipWorkingDirectory, prefix: "extract-", suffix: "")
        if let destination {
            do {
                guard !destination.isStale, startAccessing(destination.url) else {
                    throw IPhoneUSBExportError.destinationAccessDenied
                }
                scopedURL = destination.url
                try validateDestination(destination)
                let rootType = try fileManager.attributesOfItem(atPath: destination.url.path)[.type] as? FileAttributeType
                guard rootType == .typeDirectory else { throw IPhoneUSBExportError.destinationAccessDenied }
                collect(in: destination.url.appendingPathComponent(Self.partialDirectoryName, isDirectory: true),
                        prefix: "export-", suffix: ".partial")
                result.usbChecked = true
            } catch {
                result.failures.append("SD/USB 임시파일 확인 실패 · \(IPhoneReceiveErrorMessage.message(error))")
            }
        }
        for (index, item) in candidates.enumerated() {
            progress(FileDeletionProgress(totalCount: candidates.count, processedCount: index,
                failedCount: result.failures.count, currentName: item.lastPathComponent))
            do {
                try fileManager.removeItem(at: item)
                guard !fileManager.fileExists(atPath: item.path) else { throw IPhoneUSBExportError.copyFailed }
                result.deletedCount += 1
            } catch {
                result.failures.append("정리 실패 · \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        progress(FileDeletionProgress(totalCount: candidates.count, processedCount: candidates.count,
            failedCount: result.failures.count, currentName: nil))
        return result
    }

    func export(
        _ files: [IPhoneStoredFile],
        to destination: USBBookmarkDestination,
        archiveMode: IPhoneReceiveArchiveMode = .extract
    ) -> IPhoneUSBExportSummary {
        guard !files.isEmpty else {
            return IPhoneUSBExportSummary(verified: [], failed: [])
        }
        var verified: [IPhoneUSBDeletionDecision] = []
        var failed: [IPhoneUSBExportFailure] = []
        var cancelled = false
        cleanupFailures = []
        for (index, file) in files.enumerated() {
            do {
                try Task.checkCancellation()
                let decision = try exportOne(
                    file,
                    to: destination,
                    currentIndex: index + 1,
                    totalCount: files.count,
                    completedCount: verified.count,
                    archiveMode: archiveMode
                )
                verified.append(decision)
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                let reason = Self.failure(sourceID: file.id, error: error)
                let last = progressStore.snapshot()
                let phase = last.detail ?? (last.stage == .extracting ? "압축 해제" : "USB 복사")
                failed.append(IPhoneUSBExportFailure(sourceID: file.id, error: reason.error,
                    detail: "\(phase)\n\(reason.message)"))
            }
        }
        let summary = IPhoneUSBExportSummary(verified: verified, failed: failed,
            cancelled: cancelled, cleanupWarning: cleanupFailures.isEmpty ? nil : cleanupFailures.joined(separator: "\n"))
        if cancelled {
            progressStore.publish(USBReceiveProgress(
                stage: .cancelled, deliveryID: nil, fileName: nil, currentIndex: verified.count,
                totalCount: files.count, completedCount: verified.count, bytesReceived: 0,
                totalBytes: 0, startedAt: nil, expiresAt: nil, errorMessage: summary.cleanupWarning,
                detail: cleanupFailures.isEmpty ? "복사 취소 · 임시파일 정리 완료 · 원본 유지" : "복사 취소 · 일부 임시파일 정리 실패"))
        } else if failed.isEmpty {
            let copiedBytes = verified.reduce(Int64(0)) { total, record in
                total + (record.copiedFiles?.reduce(Int64(0)) { $0 + $1.size } ?? record.sourceSize)
            }
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
        if deletionStore.pending().isEmpty { progressStore.clearCompleted() }
    }

    /// Read-only, explicit verification. A failure never removes the USB copy
    /// or the iPhone original and never changes copy/deletion decisions.
    func verifyCopies(
        _ files: [IPhoneStoredFile],
        to destination: USBBookmarkDestination,
        progress: @Sendable (USBReceiveProgress) -> Void = { _ in }
    ) -> IPhoneUSBExportSummary {
        var verified: [IPhoneUSBDeletionDecision] = []
        var failures: [IPhoneUSBExportFailure] = []
        let records = deletionStore.copies()
        for (index, file) in files.enumerated() {
            var currentName = file.name
            do {
                guard !destination.isStale else { throw IPhoneUSBExportError.staleDestination }
                guard startAccessing(destination.url) else { throw IPhoneUSBExportError.destinationAccessDenied }
                defer { stopAccessing(destination.url) }
                let volume = try volumeIdentity(destination.url) ?? destination.url.path
                guard volume == destination.volumeID else { throw IPhoneUSBExportError.destinationChanged }
                guard let record = records.last(where: {
                    $0.sourceID == file.id && $0.usbVolumeID == volume
                }), let entries = record.copiedFiles else {
                    throw IPhoneUSBExportError.verificationRecordMissing
                }
                let root = destination.url.resolvingSymlinksInPath().standardizedFileURL
                let target = root.appendingPathComponent(record.usbStoredName)
                    .resolvingSymlinksInPath().standardizedFileURL
                guard target.path.hasPrefix(root.path + "/"), fileManager.fileExists(atPath: target.path) else {
                    throw IPhoneUSBExportError.destinationNotWritable
                }
                let total = entries.reduce(Int64(0)) { $0 + $1.size }
                var done: Int64 = 0
                let startedAt = now()
                for (entryIndex, entry) in entries.enumerated() {
                    currentName = entry.path.isEmpty ? record.usbStoredName : entry.path
                    let url = (entry.path.isEmpty ? target : target.appendingPathComponent(entry.path))
                        .resolvingSymlinksInPath().standardizedFileURL
                    guard url == target || url.path.hasPrefix(target.path + "/") else {
                        throw IPhoneUSBExportError.destinationChanged
                    }
                    guard try fileSize(url) == entry.size else { throw IPhoneUSBExportError.sizeMismatch }
                    let digest = try hashFile(url) { bytes in
                        progress(USBReceiveProgress(stage: .verifying, deliveryID: nil,
                            fileName: file.name, currentIndex: index + 1,
                            totalCount: files.count, completedCount: verified.count,
                            bytesReceived: done + bytes, totalBytes: total, startedAt: startedAt,
                            expiresAt: nil, errorMessage: nil,
                            detail: "선택 SHA 검증 \(entryIndex + 1)/\(entries.count)개\n\(currentName)"))
                    }
                    guard digest == entry.sha256 else { throw IPhoneUSBExportError.shaMismatch }
                    done += entry.size
                }
                verified.append(record)
            } catch {
                let failure = Self.failure(sourceID: file.id, error: error)
                failures.append(IPhoneUSBExportFailure(sourceID: file.id, error: failure.error,
                    detail: "정밀 검증 · \(currentName)\n\(failure.message)\nUSB 복사본과 iPhone 원본은 삭제하지 않았습니다."))
            }
        }
        // The caller presents verification separately from the saved copy result.
        return IPhoneUSBExportSummary(verified: verified, failed: failures)
    }

    func delete(decisionIDs: Set<UUID>) -> IPhoneUSBDeletionSummary {
        let selected = deletionStore.pending().filter { decisionIDs.contains($0.id) }
        var deleted: [String] = []
        var failed: [IPhoneUSBExportFailure] = []
        for decision in selected {
            do {
                guard try fileSize(decision.sourceURL) == decision.sourceSize else {
                    throw IPhoneUSBExportError.sourceChanged
                }
                if decision.copiedFiles != nil {
                    guard let savedDate = decision.sourceModifiedAt,
                          try modificationDate(decision.sourceURL) == savedDate else {
                        throw IPhoneUSBExportError.sourceChanged
                    }
                } else if try hashFile(decision.sourceURL) != decision.sourceSHA256 {
                    throw IPhoneUSBExportError.sourceChanged
                }
                try fileManager.removeItem(at: decision.sourceURL)
                try deletionStore.remove(ids: [decision.id])
                deleted.append(decision.sourceID)
            } catch {
                failed.append(Self.failure(sourceID: decision.sourceID, error: error))
            }
        }
        if failed.isEmpty, deletionStore.pending().isEmpty {
            progressStore.clearCompleted()
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
        completedCount: Int,
        archiveMode: IPhoneReceiveArchiveMode
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
        let sourceModifiedAt = try modificationDate(file.url)
        if let record = file.receivedRecord, record.size != sourceSize {
            throw IPhoneUSBExportError.sourceChanged
        }
        if file.url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame,
           archiveMode == .extract {
            return try exportZIP(
                file,
                to: destination,
                sourceSize: sourceSize,
                currentIndex: currentIndex,
                totalCount: totalCount,
                completedCount: completedCount,
                startedAt: startedAt
            )
        }
        // Actual writes, close errors and size checks gate completion. Full USB
        // readback is a separate user action, never part of default copying.

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
        defer { removeExportTemporaryItem(partialURL) }

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
        guard try fileSize(file.url) == sourceSize,
              try modificationDate(file.url) == sourceModifiedAt else {
            throw IPhoneUSBExportError.sourceChanged
        }

        let storedName = try IPhoneLocalFileNaming.availableName(
            requestedName: file.name,
            in: destination.url,
            fileManager: fileManager
        )
        let finalURL = destination.url.appendingPathComponent(storedName)
        try Task.checkCancellation()
        try coordinatedMove(from: partialURL, to: finalURL)
        publish(
            file: file,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytes: sourceSize,
            startedAt: startedAt,
            stage: .finalizing,
            detail: "복사 결과 파일 크기 확인 중"
        )
        guard try fileSize(finalURL) == sourceSize else {
            throw IPhoneUSBExportError.sizeMismatch
        }

        let decision = IPhoneUSBDeletionDecision(
            id: UUID(),
            sourceID: file.id,
            sourceURL: file.url,
            sourceSize: sourceSize,
            sourceSHA256: sourceSHA,
            usbStoredName: storedName,
            verifiedAt: now(),
            copiedFiles: [USBCopyFileDigest(path: "", size: sourceSize, sha256: sourceSHA)],
            usbVolumeID: destination.volumeID,
            sourceModifiedAt: sourceModifiedAt
        )
        try deletionStore.save(decision)
        return decision
    }

    private func exportZIP(
        _ file: IPhoneStoredFile,
        to destination: USBBookmarkDestination,
        sourceSize: Int64,
        currentIndex: Int,
        totalCount: Int,
        completedCount: Int,
        startedAt: Date
    ) throws -> IPhoneUSBDeletionDecision {
        var phaseStartedAt = startedAt
        func report(_ stage: USBReceiveStage, _ bytes: Int64, _ total: Int64, _ detail: String) {
            publish(file: file, currentIndex: currentIndex, totalCount: totalCount,
                    completedCount: completedCount, bytes: bytes, totalBytes: total,
                    startedAt: phaseStartedAt, stage: stage, detail: detail)
        }
        let sourceModifiedAt = try modificationDate(file.url)

        try fileManager.createDirectory(
            at: zipWorkingDirectory,
            withIntermediateDirectories: true
        )
        let extractionRoot = zipWorkingDirectory.appendingPathComponent(
            "extract-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { removeExportTemporaryItem(extractionRoot) }

        let extraction: SafeZIPExtraction
        do {
            extraction = try SafeZIPExtractor(fileManager: fileManager)
                .extract(file.url, to: extractionRoot) { bytes, total, name, done, count in
                    report(.extracting, bytes, total, "1/2 · 압축 해제·손상 검사 \(done)/\(count)개\n\(name)")
                }
        } catch SafeZIPExtractorError.unsafeArchive {
            throw IPhoneUSBExportError.unsafeZIPArchive
        } catch SafeZIPExtractorError.extractionFailed {
            throw IPhoneUSBExportError.zipExtractionFailed
        }

        guard try fileSize(file.url) == sourceSize,
              try modificationDate(file.url) == sourceModifiedAt else {
            throw IPhoneUSBExportError.sourceChanged
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
            "export-\(UUID().uuidString.lowercased()).partial",
            isDirectory: true
        )
        try fileManager.createDirectory(at: partialURL, withIntermediateDirectories: true)
        defer { removeExportTemporaryItem(partialURL) }

        phaseStartedAt = now()
        report(.copyingToUSB, 0, extraction.totalBytes, "2/2 · USB 폴더 생성 준비")
        for (index, relativePath) in extraction.directories.enumerated() {
            try Task.checkCancellation()
            report(.copyingToUSB, 0, extraction.totalBytes,
                   "2/2 · USB 폴더 생성 \(index)/\(extraction.directories.count)개\n\(relativePath)")
            try fileManager.createDirectory(
                at: partialURL.appendingPathComponent(relativePath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        var copiedBytes: Int64 = 0
        var copiedFiles: [USBCopyFileDigest] = []
        for extractedFile in extraction.files {
            try Task.checkCancellation()
            report(.copyingToUSB, copiedBytes, extraction.totalBytes,
                   "2/2 · USB 복사 \(copiedFiles.count)/\(extraction.files.count)개\n\(extractedFile.relativePath)")
            let partialFile = partialURL.appendingPathComponent(extractedFile.relativePath)
            // The full parent-directory inventory was created above, once.
            guard fileManager.createFile(atPath: partialFile.path, contents: nil) else {
                throw IPhoneUSBExportError.destinationNotWritable
            }
            let copiedSHA = try copyAndHash(
                source: extractedFile.url,
                destination: partialFile,
                progress: { bytes in
                    self.publish(
                        file: file,
                        currentIndex: currentIndex,
                        totalCount: totalCount,
                        completedCount: completedCount,
                        bytes: copiedBytes + bytes,
                        totalBytes: extraction.totalBytes,
                        startedAt: phaseStartedAt,
                        detail: "2/2 · USB 복사 \(copiedFiles.count)/\(extraction.files.count)개\n\(extractedFile.relativePath)"
                    )
                }
            )
            guard try fileSize(partialFile) == extractedFile.size else {
                throw IPhoneUSBExportError.sizeMismatch
            }
            copiedBytes += extractedFile.size
            copiedFiles.append(USBCopyFileDigest(
                path: extractedFile.relativePath,
                size: extractedFile.size,
                sha256: copiedSHA
            ))
            report(.copyingToUSB, copiedBytes, extraction.totalBytes,
                   "2/2 · USB 복사 \(copiedFiles.count)/\(extraction.files.count)개\n\(extractedFile.relativePath)")
        }

        let requestedFolderName = (file.name as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedName = try IPhoneLocalFileNaming.availableName(
            requestedName: requestedFolderName.isEmpty ? "압축해제" : requestedFolderName,
            in: destination.url,
            fileManager: fileManager
        )
        let finalURL = destination.url.appendingPathComponent(storedName, isDirectory: true)
        try Task.checkCancellation()
        try coordinatedMove(from: partialURL, to: finalURL)
        publish(
            file: file,
            currentIndex: currentIndex,
            totalCount: totalCount,
            completedCount: completedCount,
            bytes: copiedBytes,
            totalBytes: extraction.totalBytes,
            startedAt: startedAt,
            stage: .finalizing,
            detail: "복사 결과 저장·임시 압축해제 파일 정리 중"
        )

        let decision = IPhoneUSBDeletionDecision(
            id: UUID(),
            sourceID: file.id,
            sourceURL: file.url,
            sourceSize: sourceSize,
            sourceSHA256: file.receivedRecord?.sha256 ?? "",
            usbStoredName: storedName,
            verifiedAt: now(),
            copiedFiles: copiedFiles,
            usbVolumeID: destination.volumeID,
            sourceModifiedAt: sourceModifiedAt
        )
        try deletionStore.save(decision)
        return decision
    }

    private func removeExportTemporaryItem(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            cleanupFailures.append("임시파일 정리 실패 · \(url.lastPathComponent): \(error.localizedDescription)")
        }
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
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty else { return false }
                try output.write(contentsOf: data)
                try Task.checkCancellation()
                hasher.update(data: data)
                copied += Int64(data.count)
                progress(copied)
                return true
            }) {
            }
            // FileHandle writes are unbuffered at the application layer. Close
            // and propagate write/close errors without fsync on every tiny file.
            try input.close()
            try output.close()
            try Task.checkCancellation()
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

    private func modificationDate(_ url: URL) throws -> Date? {
        try fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func hashFile(_ url: URL, progress: (Int64) -> Void = { _ in }) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var processedBytes: Int64 = 0
        progress(0)
        // FileHandle can retain autoreleased buffers until this long operation returns.
        // Drain each chunk so verifying multi-GB files uses bounded memory.
        while try autoreleasepool(invoking: {
            guard let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty else { return false }
            hasher.update(data: data)
            processedBytes += Int64(data.count)
            progress(processedBytes)
            return true
        }) {
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
        totalBytes: Int64? = nil,
        startedAt: Date,
        stage: USBReceiveStage = .copyingToUSB,
        detail: String? = nil
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
            totalBytes: totalBytes ?? file.size,
            startedAt: startedAt,
            expiresAt: nil,
            errorMessage: nil,
            detail: detail
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
        var diagnostics = "\(systemError.domain) · \(systemError.code)"
        var underlying = systemError.userInfo[NSUnderlyingErrorKey] as? NSError
        for _ in 0..<4 {
            guard let cause = underlying else { break }
            diagnostics += " → \(cause.domain) · \(cause.code)"
            underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let path = systemError.userInfo[NSFilePathErrorKey] as? String {
            diagnostics += " · \((path as NSString).lastPathComponent)"
        }
        if let debug = systemError.userInfo["NSDebugDescription"] as? String {
            diagnostics += " · \(debug.prefix(512))"
        }
        let message = systemError.domain == NSCocoaErrorDomain && systemError.code == CocoaError.Code.fileReadUnknown.rawValue
            ? "파일을 읽지 못했습니다. 파일 손상으로 판정한 것은 아닙니다."
            : IPhoneReceiveErrorMessage.message(normalized)
        return IPhoneUSBExportFailure(
            sourceID: sourceID,
            error: normalized,
            detail: "\(message) (\(diagnostics))"
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
