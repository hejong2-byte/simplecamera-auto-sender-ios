import Foundation
import UniformTypeIdentifiers

enum ManualDocumentSourceError: LocalizedError {
    case unavailable
    case invalidFile
    case changed
    case storage

    var errorDescription: String? {
        switch self {
        case .unavailable: "파일을 읽을 수 없습니다. 파일 앱의 다운로드와 접근 권한을 확인해 주세요."
        case .invalidFile: "폴더, 연결 파일 또는 빈 파일은 전송할 수 없습니다."
        case .changed: "준비 중 원본 파일이 변경되었습니다. 다시 선택해 주세요."
        case .storage: "전송 준비 공간이 부족합니다. iPhone 저장 공간을 확인해 주세요."
        }
    }
}

struct ManualDocumentSource: Sendable {
    var maxBytes: Int64 = ManualMediaUploadLimit.maxBytes

    func exportOriginal(fileURL: URL, identifier: String, to directory: URL) async throws -> ManualMediaExport {
        try Task.checkCancellation()
        guard fileURL.isFileURL else { throw ManualDocumentSourceError.unavailable }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ManualDocumentSourceError.invalidFile
        }
        let name = fileURL.lastPathComponent
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileURL.pathExtension)
        var result: Result<ManualMediaExport, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                let before = try manager.attributesOfItem(atPath: coordinatedURL.path)
                guard before[.type] as? FileAttributeType == .typeRegular,
                      let size = (before[.size] as? NSNumber)?.int64Value, size > 0 else {
                    throw ManualDocumentSourceError.invalidFile
                }
                guard size <= maxBytes else { throw ManualMediaUploadError.fileTooLarge(maxBytes: maxBytes) }
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                try manager.copyItem(at: coordinatedURL, to: destination)
                let after = try manager.attributesOfItem(atPath: coordinatedURL.path)
                let copy = try manager.attributesOfItem(atPath: destination.path)
                guard after[.type] as? FileAttributeType == .typeRegular,
                      (after[.size] as? NSNumber)?.int64Value == size,
                      after[.modificationDate] as? Date == before[.modificationDate] as? Date,
                      copy[.type] as? FileAttributeType == .typeRegular,
                      (copy[.size] as? NSNumber)?.int64Value == size else {
                    throw ManualDocumentSourceError.changed
                }
                try manager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path
                )
                return ManualMediaExport(
                    assetIdentifier: identifier, fileURL: destination, fileName: name,
                    contentType: UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream",
                    capturedAt: nil
                )
            }
        }
        do {
            if let coordinationError { throw coordinationError }
            try Task.checkCancellation()
            guard let result else { throw ManualDocumentSourceError.unavailable }
            return try result.get()
        } catch {
            // This UUID path belongs only to this preparation; never remove the picked URL.
            try? manager.removeItem(at: destination)
            if error is ManualDocumentSourceError || error is ManualMediaUploadError { throw error }
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == 28)
                || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == 28) {
                throw ManualDocumentSourceError.storage
            }
            throw ManualDocumentSourceError.unavailable
        }
    }
}
