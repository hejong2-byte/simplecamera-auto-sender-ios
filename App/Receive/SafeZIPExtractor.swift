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

    func extract(_ source: URL, to destination: URL) throws -> SafeZIPExtraction {
        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw SafeZIPExtractorError.extractionFailed
        }

        for entry in archive {
            let entryURL = destination.appendingPathComponent(entry.path)
            guard entryURL.isContained(in: destination), entry.type != .symlink else {
                throw SafeZIPExtractorError.unsafeArchive
            }
        }

        do {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            try fileManager.unzipItem(
                at: source,
                to: destination,
                skipCRC32: false,
                allowUncontainedSymlinks: false
            )
        } catch {
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
