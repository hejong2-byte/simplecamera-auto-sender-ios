import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class SimpleCameraMetadataMatcherTests: XCTestCase {
    private let matcher = SimpleCameraMetadataMatcher()

    func testAcceptsTargetResolutionWithoutIPhoneMarker() {
        XCTAssertTrue(matcher.matches(properties: fixture()))
        XCTAssertTrue(matcher.matches(properties: fixture(
            width: 8064,
            height: 6048
        )))
    }

    func testRejectsIPhoneCameraModelAtSameResolution() {
        XCTAssertFalse(matcher.matches(properties: fixture(
            cameraModel: "Apple iPhone 14"
        )))
    }

    func testRejectsIPhoneLensModelAtSameResolutionIgnoringCase() {
        XCTAssertFalse(matcher.matches(properties: fixture(
            lensModel: "IPHONE 14 back camera"
        )))
    }

    func testRejectsWrongResolution() {
        XCTAssertFalse(matcher.matches(properties: fixture(
            width: 4032,
            height: 3024
        )))
    }

    func testRejectsUnreadableFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try matcher.matches(fileURL: url))
    }

    private func fixture(
        width: Int = 6048,
        height: Int = 8064,
        cameraModel: String? = nil,
        lensModel: String? = nil
    ) -> SimpleCameraPhotoProperties {
        .init(
            pixelWidth: width,
            pixelHeight: height,
            cameraModel: cameraModel,
            lensModel: lensModel
        )
    }
}
