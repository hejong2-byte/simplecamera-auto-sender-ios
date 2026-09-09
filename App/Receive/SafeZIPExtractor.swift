import Foundation
import ZIPFoundation

enum SafeZIPExtractorError: Error, Equatable {
    case unsafeArchive
    case extractionFailed
}

struct SafeZIPExtractedFile {
    let relativePath: String
    let url: URL
    let size: Int64
}

struct SafeZIPExtraction {
    let files: [SafeZIPExtractedFile]
    let directories: [String]
    let totalBytes: Int64
}

struct SafeZIPExtractor {
    let fileManager: FileManager

    func extract(_ source: URL, to destination: URL,
                 progress: @escaping (Int64, Int64, String, Int, Int) -> Void = { _, _, _, _, _ in }) throws -> SafeZIPExtraction {
        try Task.checkCancellation()
        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw SafeZIPExtractorError.extractionFailed
        }

        var entryCount = 0
        var totalBytes: Int64 = 0
        for entry in archive {
            try Task.checkCancellation()
            entryCount += 1
            let entryURL = destination.appendingPathComponent(entry.path)
            guard entryURL.isContained(in: destination), entry.type != .symlink else {
                throw SafeZIPExtractorError.unsafeArchive
            }
            guard let size = Int64(exactly: entry.uncompressedSize), size <= Int64.max - totalBytes else {
                throw SafeZIPExtractorError.unsafeArchive
            }
            if entry.type == .file { totalBytes += size }
        }

        do {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            var completedBytes: Int64 = 0
            for (index, entry) in archive.enumerated() {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let base = completedBytes
                    let entrySize = entry.type == .file ? Int64(entry.uncompressedSize) : 0
                    let entryProgress = Progress(totalUnitCount: entrySize)
                    progress(base, totalBytes, entry.path, index, entryCount)
                    try Task.checkCancellation()
                    let observation = entryProgress.observe(\.completedUnitCount, options: [.new]) { value, _ in
                        if Task.isCancelled { value.cancel() }
                        progress(base + min(entrySize, max(0, value.completedUnitCount)), totalBytes,
                                 entry.path, index, entryCount)
                    }
                    defer { observation.invalidate() }
                    let checksum = try archive.extract(entry, to: destination.appendingPathComponent(entry.path),
                                                       bufferSize: 1_024 * 1_024, skipCRC32: false,
                                                       allowUncontainedSymlinks: false, progress: entryProgress)
                    try Task.checkCancellation()
                    guard checksum == entry.checksum else { throw SafeZIPExtractorError.extractionFailed }
                    completedBytes += entrySize
                    progress(completedBytes, totalBytes, entry.path, index + 1, entryCount)
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain,
               value.code == CocoaError.Code.fileReadInvalidFileName.rawValue {
                throw SafeZIPExtractorError.unsafeArchive
            }
            if Self.isOutOfSpace(error) { throw error }
            throw SafeZIPExtractorError.extractionFailed
        }

        return try inventory(in: destination)
    }

    private func inventory(in root: URL) throws -> SafeZIPExtraction {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw SafeZIPExtractorError.extractionFailed
        }

        var files: [SafeZIPExtractedFile] = []
        var directories: [String] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                throw SafeZIPExtractorError.extractionFailed
            }
            guard values.isSymbolicLink != true,
                  let relativePath = relativePath(of: url, under: root) else {
                throw SafeZIPExtractorError.unsafeArchive
            }
            if values.isDirectory == true {
                directories.append(relativePath)
            } else if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                files.append(SafeZIPExtractedFile(
                    relativePath: relativePath,
                    url: url,
                    size: size
                ))
                totalBytes += size
            } else {
                throw SafeZIPExtractorError.unsafeArchive
            }
        }
        if enumerationError != nil {
            throw SafeZIPExtractorError.extractionFailed
        }
        return SafeZIPExtraction(
            files: files.sorted { $0.relativePath < $1.relativePath },
            directories: directories.sorted(),
            totalBytes: totalBytes
        )
    }

    private func relativePath(of item: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else { return nil }
        return String(itemPath.dropFirst(prefix.count))
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain
            && value.code == CocoaError.Code.fileWriteOutOfSpace.rawValue)
            || (value.domain == NSPOSIXErrorDomain
                && value.code == Int(POSIXErrorCode.ENOSPC.rawValue))
    }
}
