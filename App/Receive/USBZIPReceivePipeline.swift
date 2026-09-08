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

enum USBZIPReceivePipelineError: Error, Equatable {
    case unsafeArchive
    case extractionFailed
    case destinationNotWritable
    case insufficientSpace
    case sizeMismatch
    case shaMismatch
    case copyFailed
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
        progress: (USBZIPReceiveProgress) -> Void
    ) throws -> USBZIPCommit {
        do {
            return try performCommit(
                zip: zip,
                delivery: delivery,
                destination: destination,
                progress: progress
            )
        } catch let error as USBZIPReceivePipelineError {
            throw error
        } catch {
            if error is CancellationError { throw error }
            throw Self.isOutOfSpace(error) ? .insufficientSpace : .copyFailed
        }
    }

    func verify(zip: URL, committedFolder: URL) throws -> Bool {
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
            let extraction = try extract(zip, to: extractionRoot)
            let expected = try manifest(for: extraction)
            return try tree(at: committedFolder, matches: expected)
        } catch let error as USBZIPReceivePipelineError {
            throw error
        } catch {
            throw Self.isOutOfSpace(error) ? .insufficientSpace : .copyFailed
        }
    }

    private func performCommit(
        zip: URL,
        delivery: IPhoneDelivery,
        destination: URL,
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
        let extraction = try extract(zip, to: extractionRoot)

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

        let requestedName = (delivery.fileName as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalFolderName = try IPhoneLocalFileNaming.availableName(
            requestedName: requestedName.isEmpty ? "압축해제" : requestedName,
            in: destination,
            fileManager: fileManager
        )
        let finalURL = destination.appendingPathComponent(finalFolderName, isDirectory: true)
        try coordinatedMove(from: partialURL, to: finalURL)
        do {
            guard try tree(at: finalURL, matches: expected) else {
                throw USBZIPReceivePipelineError.shaMismatch
            }
        } catch {
            try? fileManager.removeItem(at: finalURL)
            throw error
        }
        return USBZIPCommit(
            finalFolderName: finalFolderName,
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
        while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
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
