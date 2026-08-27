import Foundation

enum ManualMultipartFilesError: Error, Equatable {
    case invalidPartSize
    case emptySource
}

enum ManualMultipartFiles {
    typealias Reader = (FileHandle, Int) throws -> Data

    static func makeParts(
        source: URL,
        directory: URL,
        partBytes: Int = ManualMediaUploadLimit.multipartPartBytes,
        reader: Reader = { handle, count in
            try handle.read(upToCount: count) ?? Data()
        }
    ) throws -> [URL] {
        guard partBytes > 0 else {
            throw ManualMultipartFilesError.invalidPartSize
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }

        var parts: [URL] = []
        var reachedEnd = false
        while !reachedEnd {
            var bytes = Data()
            while bytes.count < partBytes {
                let chunk = try reader(handle, partBytes - bytes.count)
                if chunk.isEmpty {
                    reachedEnd = true
                    break
                }
                bytes.append(chunk)
            }
            guard !bytes.isEmpty else { break }
            let partURL = directory.appendingPathComponent(
                String(format: "part-%05d.bin", parts.count + 1)
            )
            try bytes.write(to: partURL, options: .atomic)
            parts.append(partURL)
        }
        guard !parts.isEmpty else {
            throw ManualMultipartFilesError.emptySource
        }
        return parts
    }
}
