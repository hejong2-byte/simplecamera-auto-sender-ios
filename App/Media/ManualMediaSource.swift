import Foundation
import Photos
import UniformTypeIdentifiers

struct ManualMediaExport: Sendable, Equatable {
    let assetIdentifier: String
    let fileURL: URL
    let fileName: String
    let contentType: String
    let capturedAt: Date?
}

protocol ManualMediaSourcing: Sendable {
    func exportOriginal(
        assetIdentifier: String,
        kind: ManualMediaKind,
        to directory: URL
    ) async throws -> ManualMediaExport
}

enum ManualMediaSourceError: Error, Equatable {
    case assetNotFound
    case kindMismatch
    case originalResourceNotFound
    case unsupportedContentType
}

enum ManualMediaResourceSelection {
    static func preferredType(
        kind: ManualMediaKind,
        assetMediaType: PHAssetMediaType,
        mediaSubtypes: PHAssetMediaSubtype,
        resourceTypes: [PHAssetResourceType]
    ) -> PHAssetResourceType? {
        switch kind {
        case .photo:
            guard assetMediaType == .image else { return nil }
            return firstAvailable([.photo, .fullSizePhoto], in: resourceTypes)
        case .screenshot:
            guard assetMediaType == .image,
                  mediaSubtypes.contains(.photoScreenshot) else {
                return nil
            }
            return firstAvailable([.photo, .fullSizePhoto], in: resourceTypes)
        case .video:
            guard assetMediaType == .video else { return nil }
            return firstAvailable([.video, .fullSizeVideo], in: resourceTypes)
        }
    }

    private static func firstAvailable(
        _ preferred: [PHAssetResourceType],
        in available: [PHAssetResourceType]
    ) -> PHAssetResourceType? {
        preferred.first(where: available.contains)
    }
}

struct PhotoKitManualMediaSource: ManualMediaSourcing {
    private static let supportedContentTypes = Set([
        "image/jpeg",
        "image/png",
        "image/heic",
        "image/heif",
        "video/quicktime",
        "video/mp4",
    ])

    func exportOriginal(
        assetIdentifier: String,
        kind: ManualMediaKind,
        to directory: URL
    ) async throws -> ManualMediaExport {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        ).firstObject else {
            throw ManualMediaSourceError.assetNotFound
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let preferredType = ManualMediaResourceSelection.preferredType(
            kind: kind,
            assetMediaType: asset.mediaType,
            mediaSubtypes: asset.mediaSubtypes,
            resourceTypes: resources.map(\.type)
        ) else {
            throw ManualMediaSourceError.kindMismatch
        }
        guard let resource = resources.first(where: { $0.type == preferredType }) else {
            throw ManualMediaSourceError.originalResourceNotFound
        }
        guard let contentType = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType,
              Self.supportedContentTypes.contains(contentType) else {
            throw ManualMediaSourceError.unsupportedContentType
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let originalName = Self.safeOriginalName(
            resource.originalFilename,
            contentType: contentType
        )
        let suffix = URL(fileURLWithPath: originalName).pathExtension
        var destination = directory.appendingPathComponent(UUID().uuidString)
        if !suffix.isEmpty {
            destination.appendPathExtension(suffix)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return ManualMediaExport(
            assetIdentifier: assetIdentifier,
            fileURL: destination,
            fileName: originalName,
            contentType: contentType,
            capturedAt: asset.creationDate
        )
    }

    private static func safeOriginalName(
        _ value: String,
        contentType: String
    ) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent
        guard !name.isEmpty else {
            return contentType.hasPrefix("video/") ? "video.mov" : "photo.jpg"
        }
        return String(name.prefix(240))
    }
}
