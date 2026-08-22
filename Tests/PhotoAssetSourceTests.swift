import Photos
import XCTest
@testable import SimpleCameraAutoSender

final class PhotoAssetSourceTests: XCTestCase {
    func testPrefersOriginalPhoto() {
        XCTAssertEqual(
            PhotoAssetResourceSelection.preferredType(in: [.fullSizePhoto, .photo]),
            .photo
        )
    }

    func testFallsBackToFullSizePhoto() {
        XCTAssertEqual(
            PhotoAssetResourceSelection.preferredType(in: [.fullSizePhoto]),
            .fullSizePhoto
        )
    }
}
