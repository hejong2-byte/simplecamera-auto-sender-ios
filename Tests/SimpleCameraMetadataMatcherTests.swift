import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SimpleCameraAutoSender

final class SimpleCameraMetadataMatcherTests: XCTestCase {
    func testAcceptsObservedVersionedSoftware() throws {
        let url = try makeJPEG(software: "Simple Camera 5.0.7")
        XCTAssertTrue(SimpleCameraMetadataMatcher().matches(fileURL: url))
    }

    func testAcceptsFutureVersionAndCase() throws {
        let url = try makeJPEG(software: "simple camera 6.2")
        XCTAssertTrue(SimpleCameraMetadataMatcher().matches(fileURL: url))
    }

    func testRejectsAppleCameraAndMissingSoftware() throws {
        XCTAssertFalse(SimpleCameraMetadataMatcher().matches(
            fileURL: try makeJPEG(software: "Apple Camera")
        ))
        XCTAssertFalse(SimpleCameraMetadataMatcher().matches(
            fileURL: try makeJPEG(software: nil)
        ))
    }

    private func makeJPEG(software: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        let pixel = Data([0, 128, 255, 255])
        let provider = CGDataProvider(data: pixel as CFData)!
        let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )!
        var properties: [CFString: Any] = [:]
        if let software {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFSoftware: software
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
