import CryptoKit
import Foundation

struct USBFolderContentsSummary: Equatable, Sendable {
    let folderName: String
    let fileSystemDescription: String?
    let fileCount: Int
    let directoryCount: Int
    let totalBytes: Int64
    let volumeID: String
    let folderPath: String
    let fingerprint: String

    var totalItemCount: Int { fileCount + directoryCount }
}

struct USBFolderDeletionFailure: Equatable, Sendable {
    let name: String
    let message: String
}

struct USBFolderDeletionSummary: Equatable, Sendable {
    let deletedItemCount: Int
    let remainingItemCount: Int
    let failures: [USBFolderDeletionFailure]
}

enum USBFolderCleanupError: Error, Equatable {
    case staleDestination
    case destinationUnavailable
    case destinationChanged
    case contentsChanged
}

extension USBFolderCleanupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .staleDestination:
            return "SD/USB 폴더 권한이 만료되었습니다. 폴더를 다시 선택해 주세요."
        case .destinationUnavailable:
            return "선택한 SD/USB 폴더에 접근할 수 없습니다. 연결과 폴더 권한을 확인해 주세요."
        case .destinationChanged:
            return "확인한 저장장치와 현재 저장장치가 다릅니다. 폴더를 다시 선택해 주세요."
        case .contentsChanged:
            return "확인 후 SD/USB 내용이 변경되었습니다. 안전을 위해 삭제하지 않았습니다. 다시 확인해 주세요."
        }
    }
}

actor USBFolderCleanupService {
    typealias VolumeIdentityProvider = @Sendable (URL) throws -> String?
    typealias SecurityScopeStart = @Sendable (URL) -> Bool
    typealias SecurityScopeStop = @Sendable (URL) -> Void

    private struct Item: Sendable {
        let relativePath: String
        let kind: String
        let size: Int64
        let modifiedMilliseconds: Int64
    }

    private let fileManager: FileManager
    private let volumeIdentity: VolumeIdentityProvider
    private let startAccessing: SecurityScopeStart
    private let stopAccessing: SecurityScopeStop

    init(
        fileManager: FileManager = .default,
        volumeIdentity: @escaping VolumeIdentityProvider = { url in
            try url.resourceValues(forKeys: [.volumeIdentifierKey])
                .volumeIdentifier
                .map { String(describing: $0) }
        },
        startAccessing: @escaping SecurityScopeStart = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: @escaping SecurityScopeStop = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.fileManager = fileManager
        self.volumeIdentity = volumeIdentity
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    func inspect(_ destination: USBBookmarkDestination) throws -> USBFolderContentsSummary {
        try withValidatedAccess(to: destination) { root in
            try makeSummary(root: root, destination: destination)
        }
    }

    func deleteAllContents(
        of destination: USBBookmarkDestination,
        matching expected: USBFolderContentsSummary
    ) throws -> USBFolderDeletionSummary {
        try withValidatedAccess(to: destination) { root in
            let children = try topLevelChildren(in: root)
            let current = try makeSummary(root: root, destination: destination)
            guard current.volumeID == expected.volumeID,
                  current.folderPath == expected.folderPath,
                  current.fingerprint == expected.fingerprint else {
                throw USBFolderCleanupError.contentsChanged
            }

            var failures: [USBFolderDeletionFailure] = []
            for child in children {
                var coordinationError: NSError?
                var removalError: Error?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    writingItemAt: child,
                    options: .forDeleting,
                    error: &coordinationError
                ) { coordinatedURL in
                    do {
                        try validateTopLevelItem(coordinatedURL, inside: root)
                        try fileManager.removeItem(at: coordinatedURL)
                    } catch {
                        removalError = error
                    }
                }
                let finalError: Error? = removalError ?? coordinationError
                if let error = finalError {
                    failures.append(USBFolderDeletionFailure(
                        name: child.lastPathComponent,
                        message: error.localizedDescription
                    ))
                }
            }

            let remaining = try makeSummary(root: root, destination: destination)
            return USBFolderDeletionSummary(
                deletedItemCount: max(0, expected.totalItemCount - remaining.totalItemCount),
                remainingItemCount: remaining.totalItemCount,
                failures: failures
            )
        }
    }

    private func withValidatedAccess<T>(
        to destination: USBBookmarkDestination,
        perform work: (URL) throws -> T
    ) throws -> T {
        guard !destination.isStale else { throw USBFolderCleanupError.staleDestination }
        let root = destination.url.standardizedFileURL
        guard root.isFileURL, startAccessing(root) else {
            throw USBFolderCleanupError.destinationUnavailable
        }
        defer { stopAccessing(root) }

        let rootValues = try? root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues?.isDirectory == true,
              rootValues?.isSymbolicLink != true else {
            throw USBFolderCleanupError.destinationUnavailable
        }
        if let currentVolumeID = try volumeIdentity(root) {
            guard currentVolumeID == destination.volumeID else {
                throw USBFolderCleanupError.destinationChanged
            }
        } else if destination.volumeID != root.path {
            throw USBFolderCleanupError.destinationChanged
        }
        return try work(root)
    }

    private func makeSummary(
        root: URL,
        destination: USBBookmarkDestination
    ) throws -> USBFolderContentsSummary {
        let items = try inventory(in: root)
        let fileCount = items.filter { $0.kind != "directory" }.count
        let directoryCount = items.count - fileCount
        let totalBytes = items.reduce(Int64(0)) {
            $0 + ($1.kind == "directory" ? 0 : max(0, $1.size))
        }
        let fingerprintInput = items
            .sorted { $0.relativePath < $1.relativePath }
            .map {
                "\($0.relativePath)\u{1f}\($0.kind)\u{1f}\($0.size)\u{1f}\($0.modifiedMilliseconds)"
            }
            .joined(separator: "\u{1e}")
        let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return USBFolderContentsSummary(
            folderName: destination.displayName,
            fileSystemDescription: destination.formatDescription,
            fileCount: fileCount,
            directoryCount: directoryCount,
            totalBytes: totalBytes,
            volumeID: destination.volumeID,
            folderPath: root.path,
            fingerprint: fingerprint
        )
    }

    private func inventory(in root: URL) throws -> [Item] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw USBFolderCleanupError.destinationUnavailable
        }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var items: [Item] = []
        for case let url as URL in enumerator {
            let itemURL = url.standardizedFileURL
            guard itemURL.path.hasPrefix(prefix) else {
                throw USBFolderCleanupError.destinationChanged
            }
            let values = try itemURL.resourceValues(forKeys: keys)
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            let kind: String
            if isDirectory {
                kind = "directory"
            } else if values.isSymbolicLink == true {
                kind = "symlink"
            } else {
                kind = "file"
            }
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            items.append(Item(
                relativePath: String(itemURL.path.dropFirst(prefix.count)),
                kind: kind,
                size: Int64(values.fileSize ?? 0),
                modifiedMilliseconds: Int64((modified * 1_000).rounded())
            ))
        }
        if let traversalError { throw traversalError }
        return items
    }

    private func topLevelChildren(in root: URL) throws -> [URL] {
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        try children.forEach { try validateTopLevelItem($0, inside: root) }
        return children
    }

    private func validateTopLevelItem(_ item: URL, inside root: URL) throws {
        guard item.standardizedFileURL.deletingLastPathComponent().path == root.path else {
            throw USBFolderCleanupError.destinationChanged
        }
    }
}
