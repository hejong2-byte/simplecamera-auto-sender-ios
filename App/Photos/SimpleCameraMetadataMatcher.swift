import Foundation
import ImageIO

protocol SimpleCameraMetadataMatching: Sendable {
    func matches(fileURL: URL) -> Bool
}

struct SimpleCameraPhotoProperties: Sendable, Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let cameraModel: String?
    let lensModel: String?
}

struct SimpleCameraMetadataMatcher: SimpleCameraMetadataMatching {
    func matches(fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (values[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (values[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return false
        }

        let tiff = values[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = values[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        return matches(properties: .init(
            pixelWidth: width,
            pixelHeight: height,
            cameraModel: tiff[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif[kCGImagePropertyExifLensModel] as? String
        ))
    }

    func matches(properties: SimpleCameraPhotoProperties) -> Bool {
        let targetResolution =
            (properties.pixelWidth == 6048 && properties.pixelHeight == 8064)
            || (properties.pixelWidth == 8064 && properties.pixelHeight == 6048)
        guard targetResolution else {
            return false
        }

        return !containsIPhone(properties.cameraModel)
            && !containsIPhone(properties.lensModel)
    }

    private func containsIPhone(_ value: String?) -> Bool {
        value?.localizedCaseInsensitiveContains("iphone") == true
    }
}
