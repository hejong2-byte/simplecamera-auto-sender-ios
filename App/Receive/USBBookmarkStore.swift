import Foundation

struct USBBookmarkResolution: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

protocol USBBookmarkCoding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> USBBookmarkResolution
}

struct SystemUSBBookmarkCodec: USBBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return USBBookmarkResolution(url: url, isStale: isStale)
    }
}

struct USBBookmarkDestination: Equatable, Sendable {
    let url: URL
    let volumeID: String
    let displayName: String
    let isStale: Bool
}

final class USBBookmarkStore: @unchecked Sendable {
    private struct Record: Codable {
        let bookmark: Data
        let volumeID: String
        let displayName: String
    }

    private let fileURL: URL
    private let codec: any USBBookmarkCoding
    private let lock = NSLock()

    init(fileURL: URL, codec: any USBBookmarkCoding = SystemUSBBookmarkCodec()) {
        self.fileURL = fileURL
        self.codec = codec
    }

    func save(folderURL: URL) throws {
        let values = try folderURL.resourceValues(
            forKeys: [.volumeIdentifierKey, .nameKey]
        )
        let volumeID = values.volumeIdentifier.map { String(describing: $0) }
            ?? folderURL.path
        try save(
            folderURL: folderURL,
            volumeID: volumeID,
            displayName: values.name ?? folderURL.lastPathComponent
        )
    }

    func save(folderURL: URL, volumeID: String, displayName: String) throws {
        let record = Record(
            bookmark: try codec.makeBookmark(for: folderURL),
            volumeID: volumeID,
            displayName: displayName
        )
        try lock.withLock {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
        }
    }

    func resolve() throws -> USBBookmarkDestination? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let record = try JSONDecoder().decode(
                Record.self,
                from: Data(contentsOf: fileURL)
            )
            let resolution = try codec.resolve(record.bookmark)
            return USBBookmarkDestination(
                url: resolution.url,
                volumeID: record.volumeID,
                displayName: record.displayName,
                isStale: resolution.isStale
            )
        }
    }

    func clear() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
