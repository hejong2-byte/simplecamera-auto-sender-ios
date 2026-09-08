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
    let formatDescription: String?

    init(
        url: URL,
        volumeID: String,
        displayName: String,
        isStale: Bool,
        formatDescription: String? = nil
    ) {
        self.url = url
        self.volumeID = volumeID
        self.displayName = displayName
        self.isStale = isStale
        self.formatDescription = formatDescription
    }
}

final class USBBookmarkStore: @unchecked Sendable {
    private struct Record: Codable {
        let bookmark: Data
        let volumeID: String
        let displayName: String
        let formatDescription: String?
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
        let formatValues = try? folderURL.resourceValues(
            forKeys: [.volumeLocalizedFormatDescriptionKey]
        )
        let volumeID = values.volumeIdentifier.map { String(describing: $0) }
            ?? folderURL.path
        try save(
            folderURL: folderURL,
            volumeID: volumeID,
            displayName: values.name ?? folderURL.lastPathComponent,
            formatDescription: formatValues?.volumeLocalizedFormatDescription
        )
    }

    func save(
        folderURL: URL,
        volumeID: String,
        displayName: String,
        formatDescription: String? = nil
    ) throws {
        let record = Record(
            bookmark: try codec.makeBookmark(for: folderURL),
            volumeID: volumeID,
            displayName: displayName,
            formatDescription: formatDescription
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
            let formatValues = try? resolution.url.resourceValues(
                forKeys: [.volumeLocalizedFormatDescriptionKey]
            )
            return USBBookmarkDestination(
                url: resolution.url,
                volumeID: record.volumeID,
                displayName: record.displayName,
                isStale: resolution.isStale,
                formatDescription: record.formatDescription
                    ?? formatValues?.volumeLocalizedFormatDescription
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
