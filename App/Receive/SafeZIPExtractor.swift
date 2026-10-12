import Foundation
import CoreFoundation
import ZIPFoundation

enum SafeZIPExtractorError: Error, Equatable {
    case unsafeArchive
    case extractionFailed
    case invalidSelection
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
    var archiveDirectories: [String]? = nil
}

struct SafeZIPEntry: Identifiable, Equatable, Sendable {
    let path: String
    let isDirectory: Bool
    let size: Int64
    var id: String { path }
}

struct SafeZIPExtractor {
    let fileManager: FileManager
    var capacityQuery: StorageCapacityPreflight.Query = { try StorageCapacityPreflight.system($0) }
    var capacityReport: (StorageCapacityCheck) -> Void = { _ in }

    private static let windowsKoreanEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0422))
    )

    func contents(of source: URL) throws -> [SafeZIPEntry] {
        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw SafeZIPExtractorError.extractionFailed
        }
        return try metadata(in: archive)
    }

    func extract(_ source: URL, to destination: URL, selectedPaths: Set<String>? = nil,
                 progress: @escaping (Int64, Int64, String, Int, Int) -> Void = { _, _, _, _, _ in }) throws -> SafeZIPExtraction {
        try Task.checkCancellation()
        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw SafeZIPExtractorError.extractionFailed
        }

        // Validate every entry before filtering: an unselected unsafe path still
        // makes the archive unsafe. Metadata also supplies implicit directories.
        let archiveMetadata = try metadata(in: archive)
        if let selectedPaths {
            let knownPaths = Set(archiveMetadata.map(\.path))
            guard !selectedPaths.isEmpty, selectedPaths.isSubset(of: knownPaths) else {
                throw SafeZIPExtractorError.invalidSelection
            }
        }
        func isSelected(_ path: String) -> Bool {
            guard let selectedPaths else { return true }
            return selectedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        let entries = try archive.filter { isSelected(try Self.validatedPath(for: $0)) }
        let entryCount = entries.count
        let totalBytes = archiveMetadata.filter { !$0.isDirectory && isSelected($0.path) }
            .reduce(Int64(0)) { $0 + $1.size }

        try StorageCapacityPreflight.check(at: destination.deletingLastPathComponent(), requiredBytes: totalBytes, destination: .iphoneLocal,
                                          query: capacityQuery, report: capacityReport)

        do {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            var completedBytes: Int64 = 0
            for (index, entry) in entries.enumerated() {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let entryPath = try Self.validatedPath(for: entry)
                    guard destination.appendingPathComponent(entryPath).isContained(in: destination) else {
                        throw SafeZIPExtractorError.unsafeArchive
                    }
                    let base = completedBytes
                    let entrySize = entry.type == .file ? Int64(entry.uncompressedSize) : 0
                    let entryProgress = Progress(totalUnitCount: entrySize)
                    progress(base, totalBytes, entryPath, index, entryCount)
                    try Task.checkCancellation()
                    let observation = entryProgress.observe(\.completedUnitCount, options: [.new]) { value, _ in
                        if Task.isCancelled { value.cancel() }
                        progress(base + min(entrySize, max(0, value.completedUnitCount)), totalBytes,
                                 entryPath, index, entryCount)
                    }
                    defer { observation.invalidate() }
                    let checksum = try archive.extract(entry, to: destination.appendingPathComponent(entryPath),
                                                       bufferSize: 1_024 * 1_024, skipCRC32: false,
                                                       allowUncontainedSymlinks: false, progress: entryProgress)
                    try Task.checkCancellation()
                    guard checksum == entry.checksum else { throw SafeZIPExtractorError.extractionFailed }
                    completedBytes += entrySize
                    progress(completedBytes, totalBytes, entryPath, index + 1, entryCount)
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

        var extraction = try inventory(in: destination)
        extraction.archiveDirectories = archiveMetadata.filter(\.isDirectory).map(\.path)
        return extraction
    }

    private func metadata(in archive: Archive) throws -> [SafeZIPEntry] {
        var items: [String: SafeZIPEntry] = [:]
        var explicitPaths = Set<String>()
        var totalBytes: Int64 = 0
        for entry in archive {
            try Task.checkCancellation()
            let path = try Self.validatedPath(for: entry)
            guard explicitPaths.insert(path).inserted,
                  let size = Int64(exactly: entry.uncompressedSize), size <= Int64.max - totalBytes else {
                throw SafeZIPExtractorError.unsafeArchive
            }
            let isDirectory = entry.type == .directory
            if let existing = items[path], existing.isDirectory != isDirectory {
                throw SafeZIPExtractorError.unsafeArchive
            }
            items[path] = SafeZIPEntry(path: path, isDirectory: isDirectory, size: isDirectory ? 0 : size)
            if !isDirectory { totalBytes += size }
            var components = path.split(separator: "/").map(String.init)
            components.removeLast()
            while !components.isEmpty {
                let parent = components.joined(separator: "/")
                if let existing = items[parent], !existing.isDirectory {
                    throw SafeZIPExtractorError.unsafeArchive
                }
                items[parent] = SafeZIPEntry(path: parent, isDirectory: true, size: 0)
                components.removeLast()
            }
        }
        return items.values.sorted { $0.path < $1.path }
    }

    private static func validatedPath(for entry: Entry) throws -> String {
        let raw = decodedPath(for: entry)
        let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard entry.type != .symlink, !path.isEmpty, !raw.hasPrefix("/"), !raw.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SafeZIPExtractorError.unsafeArchive
        }
        return path
    }

    private static func decodedPath(for entry: Entry) -> String {
        let utf8Path = entry.path(using: .utf8)
        if !utf8Path.isEmpty { return utf8Path }

        let windowsKoreanPath = entry.path(using: windowsKoreanEncoding)
        return windowsKoreanPath.isEmpty ? entry.path : windowsKoreanPath
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
