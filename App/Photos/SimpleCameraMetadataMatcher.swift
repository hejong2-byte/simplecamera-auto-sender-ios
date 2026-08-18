import Foundation
import ImageIO

struct SimpleCameraMetadataMatcher: Sendable {
    func matches(fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary]
                as? [CFString: Any],
              let software = tiff[kCGImagePropertyTIFFSoftware] as? String else {
            return false
        }

        let normalized = software
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "simple camera" || normalized.hasPrefix("simple camera ")
    }
}
