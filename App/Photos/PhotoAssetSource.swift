import Foundation
import Photos

struct PhotoCandidate: Sendable, Equatable {
    let localIdentifier: String
    let creationDate: Date
}

protocol PhotoAssetSourcing: Sendable {
    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate]
    func exportOriginal(localIdentifier: String, to destination: URL) async throws
}

enum PhotoAssetSourceError: Error {
    case assetNotFound
    case originalResourceNotFound
}

struct PhotoKitAssetSource: PhotoAssetSourcing {
    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate > %@",
            PHAssetMediaType.image.rawValue,
            date as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: options)
        var candidates: [PhotoCandidate] = []
        result.enumerateObjects { asset, _, _ in
            guard let creationDate = asset.creationDate else { return }
            candidates.append(PhotoCandidate(
                localIdentifier: asset.localIdentifier,
                creationDate: creationDate
            ))
        }
        return candidates
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject else {
            throw PhotoAssetSourceError.assetNotFound
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else {
            throw PhotoAssetSourceError.originalResourceNotFound
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { continuation in
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
    }
}
