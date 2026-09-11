import Foundation
import Photos
import UniformTypeIdentifiers

enum IPhoneReceivedMediaLibraryError: LocalizedError {
    case permissionDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "사진 앱에 추가할 권한이 없습니다. iPhone 설정에서 사진 추가 권한을 허용해 주세요."
        case .saveFailed:
            return "사진 앱에 파일을 추가하지 못했습니다."
        }
    }
}

enum IPhoneReceivedMediaLibrary {
    static func saveIfSupported(fileURL: URL, contentType: String) async throws -> Bool {
        let kind: MediaKind
        let type = UTType(filenameExtension: fileURL.pathExtension)
        if contentType.lowercased().hasPrefix("image/") || type?.conforms(to: .image) == true {
            kind = .image
        } else if contentType.lowercased().hasPrefix("video/") || type?.conforms(to: .movie) == true {
            kind = .video
        } else {
            return false
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw IPhoneReceivedMediaLibraryError.permissionDenied
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                switch kind {
                case .image:
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                case .video:
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                }
            } completionHandler: { succeeded, error in
                if succeeded {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? IPhoneReceivedMediaLibraryError.saveFailed)
                }
            }
        }
        return true
    }

    private enum MediaKind: Sendable {
        case image
        case video
    }
}
