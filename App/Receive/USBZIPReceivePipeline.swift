import CryptoKit
import Foundation

enum USBZIPReceivePhase: Sendable, Equatable {
    case extracting
    case copying
    case verifying
}

struct USBZIPReceiveProgress: Sendable, Equatable {
    let phase: USBZIPReceivePhase
    let completedBytes: Int64
    let totalBytes: Int64
}

struct USBZIPCommit: Sendable, Equatable {
    let finalFolderName: String
    let extractedBytes: Int64
}

struct USBZIPOverwriteRequest: Sendable, Equatable {
    let deliveryID: UUID
    let paths: [String]
}

enum USBZIPReceivePipelineError: Error, Equatable {
    case unsafeArchive
    case extractionFailed
    case destinationNotWritable
    case insufficientSpace
    case sizeMismatch
    case shaMismatch
    case copyFailed
    case overwriteRequired(USBZIPOverwriteRequest)
}

struct USBZIPReceivePipeline {
    private struct ManifestFile: Equatable {
        let path: String
        let size: Int64
        let sha256: String
    }

    private struct Manifest: Equatable {
        let files: [ManifestFile]
        let directories: [String]
    }

    private let fileManager: FileManager
    private let workingDirectory: URL

    init(
        fileManager: FileManager = .default,
        workingDirectory: URL
    ) {
        self.fileManager = fileManager
        self.workingDirectory = workingDirectory
    }

    func commit(
        zip: URL,
        delivery: IPhoneDelivery,
        destination: URL,
        overwriteExisting: Bool = false,
        progress: (USBZIPReceiveProgress) -> Void
    ) throws -> USBZIPCommit {
        do {
            return try performCommit(
                zip: zip,
                delivery: delivery,
                destination: destination,
                overwriteExisting: overwriteExisting,
                progress: progress
            )
        } catch let error as USBZIPReceivePipelineError {
            throw error
        } catch {
            if error is CancellationError { throw error }
            throw Self.isOutOfSpace(error)
                ? USBZIPReceivePipelineError.insufficientSpace
                : USBZIPReceivePipelineError.copyFailed
        }
    }

    func verify(
        zip: URL,
        archiveName: String? = nil,
        committedFolder: URL
    ) throws -> Bool {
        do {
            try fileManager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            let extractionRoot = workingDirectory.appendingPathComponent(
                "verify-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: extractionRoot) }
            let extraction = IPhoneUSBExportService.removingPackagingWrappers(
                from: try extract(zip, to: extractionRoot),
                archiveName: archiveName ?? zip.lastPathComponent
            )
            let expected = try manifest(for: extraction)
            return try layout(at: committedFolder, matches: expected)
        } catch let error as USBZIPReceivePipelineError {
            throw error
        } catch {
            throw Self.isOutOfSpace(error)
                ? USBZIPReceivePipelineError.insufficientSpace
                : USBZIPReceivePipelineError.copyFailed
        }
    }

    private func performCommit(
        zip: URL,
        delivery: IPhoneDelivery,
        destination: URL,
        overwriteExisting: Bool,
        progress: (USBZIPReceiveProgress) -> Void
    ) throws -> USBZIPCommit {
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let extractionRoot = workingDirectory.appendingPathComponent(
            "extract-\(delivery.deliveryID.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: extractionRoot) }

        progress(USBZIPReceiveProgress(
            phase: .extracting,
            completedBytes: 0,
            totalBytes: 0
        ))
        let extraction = IPhoneUSBExportService.removingPackagingWrappers(
            from: try extract(zip, to: extractionRoot),
            archiveName: delivery.fileName
        )

        let topLevelNames = Set((extraction.directories + extraction.files.map(\.relativePath))
            .compactMap { $0.split(separator: "/").first.map(String.init) }).sorted()
        for name in topLevelNames {
            guard name != USBReceiveService.partialDirectoryName else {
                throw USBZIPReceivePipelineError.destinationNotWritable
            }
        }
        let conflicts = USBStagedTreeCommitter.conflictingPaths(
            destinationRoot: destination,
            directories: extraction.directories,
            files: extraction.files.map(\.relativePath),
            fileManager: fileManager
        )
        if !overwriteExisting, !conflicts.isEmpty {
            throw USBZIPReceivePipelineError.overwriteRequired(
                USBZIPOverwriteRequest(
                    deliveryID: delivery.deliveryID,
                    paths: conflicts
                )
            )
        }

        let partialDirectory = destination.appendingPathComponent(
            USBReceiveService.partialDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: partialDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = partialDirectory.appendingPathComponent(
            "zip-\(delivery.deliveryID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).partial",
            isDirectory: true
        )
        try fileManager.createDirectory(at: partialURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: partialURL) }

        for relativePath in extraction.directories {
            try fileManager.createDirectory(
                at: partialURL.appendingPathComponent(relativePath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        var copiedBytes: Int64 = 0
        var files: [ManifestFile] = []
        progress(USBZIPReceiveProgress(
            phase: .copying,
            completedBytes: 0,
            totalBytes: extraction.totalBytes
        ))
        for extractedFile in extraction.files {
            let copiedFile = partialURL.appendingPathComponent(extractedFile.relativePath)
            try fileManager.createDirectory(
                at: copiedFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: copiedFile.path, contents: nil) else {
                throw USBZIPReceivePipelineError.destinationNotWritable
            }
            let sha256 = try copyAndHash(
                source: extractedFile.url,
                destination: copiedFile
            ) { fileBytes in
                progress(USBZIPReceiveProgress(
                    phase: .copying,
                    completedBytes: copiedBytes + fileBytes,
                    totalBytes: extraction.totalBytes
                ))
            }
            guard try regularFileSize(copiedFile) == extractedFile.size else {
                throw USBZIPReceivePipelineError.sizeMismatch
            }
            copiedBytes += extractedFile.size
            files.append(ManifestFile(
                path: extractedFile.relativePath,
                size: extractedFile.size,
                sha256: sha256
            ))
        }

        let expected = Manifest(
            files: files.sorted { $0.path < $1.path },
            directories: extraction.directories.sorted()
        )
        progress(USBZIPReceiveProgress(
            phase: .verifying,
            completedBytes: extraction.totalBytes,
            totalBytes: extraction.totalBytes
        ))
        guard try tree(at: partialURL, matches: expected) else {
            throw USBZIPReceivePipelineError.shaMismatch
        }

        let backupURL = partialDirectory.appendingPathComponent(
            "overwrite-\(UUID().uuidString.lowercased()).backup",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: backupURL) }
        try USBStagedTreeCommitter(
            fileManager: fileManager,
            moveItem: coordinatedMove
        ).commit(
            stagedRoot: partialURL,
            destinationRoot: destination,
            directories: expected.directories,
            files: expected.files.map(\.path),
            backupRoot: backupURL
        )
        guard try layout(at: destination, matches: expected) else {
            throw USBZIPReceivePipelineError.shaMismatch
        }
        return USBZIPCommit(
            finalFolderName: "",
            extractedBytes: extraction.totalBytes
        )
    }

    private func extract(_ zip: URL, to destination: URL) throws -> SafeZIPExtraction {
        do {
            return try SafeZIPExtractor(fileManager: fileManager)
                .extract(zip, to: destination)
        } catch SafeZIPExtractorError.unsafeArchive {
            throw USBZIPReceivePipelineError.unsafeArchive
        } catch SafeZIPExtractorError.extractionFailed {
            throw USBZIPReceivePipelineError.extractionFailed
        } catch {
            if Self.isOutOfSpace(error) {
                throw USBZIPReceivePipelineError.insufficientSpace
            }
            throw USBZIPReceivePipelineError.extractionFailed
        }
    }

    private func manifest(for extraction: SafeZIPExtraction) throws -> Manifest {
        Manifest(
            files: try extraction.files.map {
                ManifestFile(
                    path: $0.relativePath,
                    size: $0.size,
                    sha256: try hashFile($0.url)
                )
            }.sorted { $0.path < $1.path },
            directories: extraction.directories.sorted()
        )
    }

    private func tree(at root: URL, matches expected: Manifest) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { return false }

        var files: [ManifestFile] = []
        var directories: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true,
                  let relativePath = relativePath(of: url, under: root) else {
                return false
            }
            if values.isDirectory == true {
                directories.append(relativePath)
            } else if values.isRegularFile == true {
                files.append(ManifestFile(
                    path: relativePath,
                    size: Int64(values.fileSize ?? 0),
                    sha256: try hashFile(url)
                ))
            } else {
                return false
            }
        }
        if enumerationError != nil { return false }
        return Manifest(
            files: files.sorted { $0.path < $1.path },
            directories: directories.sorted()
        ) == expected
    }

    private func layout(at root: URL, matches expected: Manifest) throws -> Bool {
        for relativePath in expected.directories {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(
                atPath: root.appendingPathComponent(relativePath).path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else { return false }
        }
        for file in expected.files {
            let url = root.appendingPathComponent(file.path)
            guard try regularFileSize(url) == file.size,
                  try hashFile(url) == file.sha256 else { return false }
        }
        return true
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
                guard let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty else { return false }
                try output.write(contentsOf: data)
                hasher.update(data: data)
                copied += Int64(data.count)
                progress(copied)
                return true
            }) {
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

    private func regularFileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw USBZIPReceivePipelineError.sizeMismatch
        }
        return Int64(values.fileSize ?? 0)
    }

    private func hashFile(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        // FileHandle can retain autoreleased buffers until this long operation returns.
        // Drain each chunk so verifying multi-GB files uses bounded memory.
        while try autoreleasepool(invoking: {
            guard let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {
        }
        return Self.hex(hasher.finalize())
    }

    private func relativePath(of item: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else { return nil }
        return String(itemPath.dropFirst(prefix.count))
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

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain
            && value.code == CocoaError.Code.fileWriteOutOfSpace.rawValue)
            || (value.domain == NSPOSIXErrorDomain
                && value.code == Int(POSIXErrorCode.ENOSPC.rawValue))
    }
}

struct USBStagedTreeCommitter {
    typealias MoveItem = (URL, URL) throws -> Void

    private let fileManager: FileManager
    private let moveItem: MoveItem

    init(fileManager: FileManager, moveItem: @escaping MoveItem) {
        self.fileManager = fileManager
        self.moveItem = moveItem
    }

    static func conflictingPaths(
        destinationRoot: URL,
        directories: [String],
        files: [String],
        fileManager: FileManager
    ) -> [String] {
        var conflicts = Set<String>()
        for relativePath in directories {
            let target = destinationRoot.appendingPathComponent(relativePath, isDirectory: true)
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                conflicts.insert(relativePath)
            }
        }
        for relativePath in files {
            let target = destinationRoot.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: target.path) {
                conflicts.insert(relativePath)
            }
        }
        return conflicts.sorted()
    }

    func commit(
        stagedRoot: URL,
        destinationRoot: URL,
        directories: [String],
        files: [String],
        backupRoot: URL
    ) throws {
        let directoryPaths = allDirectoryPaths(directories: directories, files: files)
        var backups: [(original: URL, backup: URL)] = []
        var installedFiles: [URL] = []
        var createdDirectories: [URL] = []

        do {
            for relativePath in directoryPaths {
                let target = destinationRoot.appendingPathComponent(relativePath, isDirectory: true)
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue { continue }
                    let backup = backupRoot.appendingPathComponent(relativePath)
                    try fileManager.createDirectory(
                        at: backup.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try moveItem(target, backup)
                    backups.append((target, backup))
                }
                try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
                createdDirectories.append(target)
            }

            for relativePath in files.sorted() {
                let staged = stagedRoot.appendingPathComponent(relativePath)
                let target = destinationRoot.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: target.path) {
                    let backup = backupRoot.appendingPathComponent(relativePath)
                    try fileManager.createDirectory(
                        at: backup.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try moveItem(target, backup)
                    backups.append((target, backup))
                }
                try moveItem(staged, target)
                installedFiles.append(target)
            }
        } catch {
            for url in installedFiles.reversed() where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            for url in createdDirectories.reversed() where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            for item in backups.reversed() where fileManager.fileExists(atPath: item.backup.path) {
                if fileManager.fileExists(atPath: item.original.path) {
                    try? fileManager.removeItem(at: item.original)
                }
                try? fileManager.createDirectory(
                    at: item.original.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? moveItem(item.backup, item.original)
            }
            throw error
        }
    }

    private func allDirectoryPaths(directories: [String], files: [String]) -> [String] {
        var result = Set(directories)
        for file in files {
            var components = file.split(separator: "/").map(String.init)
            if !components.isEmpty { components.removeLast() }
            while !components.isEmpty {
                result.insert(components.joined(separator: "/"))
                components.removeLast()
            }
        }
        return result.sorted {
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            return lhsDepth == rhsDepth ? $0 < $1 : lhsDepth < rhsDepth
        }
    }
}
