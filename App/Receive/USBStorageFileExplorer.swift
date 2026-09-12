import Foundation

enum USBStorageFileEntryKind: Sendable, Equatable {
    case directory
    case file
}

struct USBStorageFileEntry: Identifiable, Sendable, Equatable {
    let relativePath: String
    let name: String
    let kind: USBStorageFileEntryKind
    let size: Int64
    let modifiedAt: Date?

    var id: String { relativePath }
}

enum USBStorageFileExplorerError: LocalizedError, Equatable {
    case destinationMissing
    case permissionExpired
    case unavailable
    case invalidPath
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .destinationMissing:
            return "SD/USB 폴더를 먼저 선택해 주세요."
        case .permissionExpired:
            return "저장장치 폴더 권한이 만료되었습니다. 다시 선택해 주세요."
        case .unavailable:
            return "SD/USB 저장장치를 다시 연결하고 폴더를 선택해 주세요."
        case .invalidPath:
            return "선택한 저장장치 안의 폴더만 열 수 있습니다."
        case .invalidFile:
            return "선택한 파일을 읽을 수 없습니다. 목록을 새로 고친 뒤 다시 선택해 주세요."
        }
    }
}

struct USBStorageFileExplorer: @unchecked Sendable {
    private static let internalDirectoryName = USBReceiveService.partialDirectoryName

    private let fileManager: FileManager
    private let startAccessing: @Sendable (URL) -> Bool
    private let stopAccessing: @Sendable (URL) -> Void

    init(
        fileManager: FileManager = .default,
        startAccessing: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccessing: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.fileManager = fileManager
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    func list(
        destination: USBBookmarkDestination,
        relativePath: String
    ) throws -> [USBStorageFileEntry] {
        try withAccess(to: destination) {
            let directory = try validatedURL(
                root: destination.url,
                relativePath: relativePath
            )
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw USBStorageFileExplorerError.invalidPath
            }

            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            let prefix = try validatedComponents(relativePath)
            return try urls.compactMap { url in
                guard url.lastPathComponent != Self.internalDirectoryName else {
                    return nil
                }
                let itemAttributes = try fileManager.attributesOfItem(atPath: url.path)
                let type = itemAttributes[.type] as? FileAttributeType
                guard type != .typeSymbolicLink else { return nil }
                let kind: USBStorageFileEntryKind
                let size: Int64
                switch type {
                case .typeDirectory:
                    kind = .directory
                    size = 0
                case .typeRegular:
                    kind = .file
                    size = (itemAttributes[.size] as? NSNumber)?.int64Value ?? 0
                default:
                    return nil
                }
                return USBStorageFileEntry(
                    relativePath: (prefix + [url.lastPathComponent]).joined(separator: "/"),
                    name: url.lastPathComponent,
                    kind: kind,
                    size: size,
                    modifiedAt: itemAttributes[.modificationDate] as? Date
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .directory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    func withFiles<T: Sendable>(
        destination: USBBookmarkDestination,
        relativePaths: [String],
        operation: @Sendable ([URL]) async throws -> T
    ) async throws -> T {
        guard !destination.isStale else {
            throw USBStorageFileExplorerError.permissionExpired
        }
        guard startAccessing(destination.url) else {
            throw USBStorageFileExplorerError.unavailable
        }
        defer { stopAccessing(destination.url) }

        do {
            var seen = Set<String>()
            let urls = try relativePaths.compactMap { relativePath -> URL? in
                let url = try validatedURL(root: destination.url, relativePath: relativePath)
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw USBStorageFileExplorerError.invalidFile
                }
                let key = url.standardizedFileURL.path
                return seen.insert(key).inserted ? url : nil
            }
            guard !urls.isEmpty else { throw USBStorageFileExplorerError.invalidFile }
            return try await operation(urls)
        } catch let error as USBStorageFileExplorerError {
            throw error
        } catch {
            throw USBStorageFileExplorerError.invalidFile
        }
    }

    private func withAccess<T>(
        to destination: USBBookmarkDestination,
        operation: () throws -> T
    ) throws -> T {
        guard !destination.isStale else {
            throw USBStorageFileExplorerError.permissionExpired
        }
        guard startAccessing(destination.url) else {
            throw USBStorageFileExplorerError.unavailable
        }
        defer { stopAccessing(destination.url) }
        do {
            return try operation()
        } catch let error as USBStorageFileExplorerError {
            throw error
        } catch {
            throw USBStorageFileExplorerError.unavailable
        }
    }

    private func validatedURL(root: URL, relativePath: String) throws -> URL {
        let components = try validatedComponents(relativePath)
        let standardizedRoot = root.standardizedFileURL
        let candidate = components.reduce(standardizedRoot) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
        let rootPath = standardizedRoot.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw USBStorageFileExplorerError.invalidPath
        }

        var current = standardizedRoot
        for component in components {
            current.appendPathComponent(component)
            let attributes = try fileManager.attributesOfItem(atPath: current.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw USBStorageFileExplorerError.invalidFile
            }
        }
        return candidate
    }

    private func validatedComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("\\") else {
            throw USBStorageFileExplorerError.invalidPath
        }
        if relativePath.isEmpty { return [] }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
        }) else {
            throw USBStorageFileExplorerError.invalidPath
        }
        return components
    }
}
