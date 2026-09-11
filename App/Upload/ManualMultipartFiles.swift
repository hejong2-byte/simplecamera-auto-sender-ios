import Foundation

enum ManualMultipartFilesError: Error, Equatable {
    case invalidPartSize
    case emptySource
    case sourceChanged
}

enum ManualMultipartFiles {
    typealias Reader = (FileHandle, Int) throws -> Data

    static func makeParts(
        source: URL,
        directory: URL,
        partBytes: Int = ManualMediaUploadLimit.defaultMultipartPartBytes,
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

    static func planParts(
        source: URL,
        directory: URL,
        partBytes: Int
    ) throws -> [ManualTransferPart] {
        guard partBytes > 0 else {
            throw ManualMultipartFilesError.invalidPartSize
        }
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let rawSize = values.fileSize, rawSize > 0 else {
            throw ManualMultipartFilesError.emptySource
        }
        let sourceSize = Int64(rawSize)
        var parts: [ManualTransferPart] = []
        var offset: Int64 = 0
        while offset < sourceSize {
            let size = min(Int64(partBytes), sourceSize - offset)
            let number = parts.count + 1
            parts.append(ManualTransferPart(
                number: number,
                fileURL: directory.appendingPathComponent(
                    String(format: "part-%05d.bin", number)
                ),
                size: size,
                etag: nil,
                retryAttempt: 0
            ))
            offset += size
        }
        return parts
    }

    static func materializePart(
        source: URL,
        part: ManualTransferPart,
        allParts: [ManualTransferPart]
    ) throws {
        if FileManager.default.fileExists(atPath: part.fileURL.path),
           try part.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(part.size) {
            return
        }
        try? FileManager.default.removeItem(at: part.fileURL)
        try FileManager.default.createDirectory(
            at: part.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let offset = allParts
            .filter { $0.number < part.number }
            .reduce(Int64(0)) { $0 + $1.size }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var bytes = Data()
        bytes.reserveCapacity(Int(part.size))
        while bytes.count < Int(part.size) {
            let remaining = Int(part.size) - bytes.count
            let chunk = try handle.read(upToCount: remaining) ?? Data()
            guard !chunk.isEmpty else {
                throw ManualMultipartFilesError.sourceChanged
            }
            bytes.append(chunk)
        }
        try bytes.write(to: part.fileURL, options: .atomic)
    }
}
