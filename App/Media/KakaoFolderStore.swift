import Foundation

enum KakaoFolderError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "폴더에 접근할 수 없습니다. 파일 앱에서 카카오톡 파일을 저장한 폴더를 다시 선택해 주세요."
    }
}

final class KakaoFolderStore: @unchecked Sendable {
    private struct Record: Codable { let bookmark: Data }
    private let fileURL: URL
    private let codec: any USBBookmarkCoding
    private let lock = NSLock()

    init(fileURL: URL, codec: any USBBookmarkCoding = SystemUSBBookmarkCodec()) {
        self.fileURL = fileURL
        self.codec = codec
    }

    func save(_ folder: URL) throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try validate(folder)
        let record = Record(bookmark: try codec.makeBookmark(for: folder))
        try lock.withLock {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
        }
    }

    func resolve() throws -> URL? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            do {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: fileURL))
                let result = try codec.resolve(record.bookmark)
                guard !result.isStale else { throw KakaoFolderError.unavailable }
                let scoped = result.url.startAccessingSecurityScopedResource()
                defer { if scoped { result.url.stopAccessingSecurityScopedResource() } }
                try validate(result.url)
                return result.url
            } catch {
                throw KakaoFolderError.unavailable
            }
        }
    }

    private func validate(_ url: URL) throws {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else { throw KakaoFolderError.unavailable }
    }
}
