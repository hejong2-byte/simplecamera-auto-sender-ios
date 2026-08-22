import Photos
import XCTest
@testable import SimpleCameraAutoSender

final class ManualMediaSourceTests: XCTestCase {
    func testPhotoAcceptsImageAndPrefersOriginalPhotoResource() {
        let result = ManualMediaResourceSelection.preferredType(
            kind: .photo,
            assetMediaType: .image,
            mediaSubtypes: [],
            resourceTypes: [.fullSizePhoto, .photo]
        )

        XCTAssertEqual(result, .photo)
    }

    func testScreenshotRequiresPhotoKitScreenshotSubtype() {
        XCTAssertNil(ManualMediaResourceSelection.preferredType(
            kind: .screenshot,
            assetMediaType: .image,
            mediaSubtypes: [],
            resourceTypes: [.photo]
        ))
        XCTAssertEqual(ManualMediaResourceSelection.preferredType(
            kind: .screenshot,
            assetMediaType: .image,
            mediaSubtypes: [.photoScreenshot],
            resourceTypes: [.photo]
        ), .photo)
    }

    func testVideoAcceptsOnlyVideoAndPrefersOriginalVideoResource() {
        XCTAssertNil(ManualMediaResourceSelection.preferredType(
            kind: .video,
            assetMediaType: .image,
            mediaSubtypes: [],
            resourceTypes: [.video]
        ))
        XCTAssertEqual(ManualMediaResourceSelection.preferredType(
            kind: .video,
            assetMediaType: .video,
            mediaSubtypes: [],
            resourceTypes: [.fullSizeVideo, .video]
        ), .video)
    }
}
